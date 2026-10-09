// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IAMB, IAMBClaimReceiver } from "./interfaces/IAMB.sol";
import { IHomeXDaiBridge } from "./interfaces/IHomeXDaiBridge.sol";
import { ISavingsXDaiAdapter } from "./interfaces/ISavingsXDaiAdapter.sol";
import { VaultClaimLib } from "./libraries/VaultClaimLib.sol";

/// @notice Durable, authenticated claims against completed canonical xDAI transfers.
contract SavingsXDaiSettlementVault is IAMBClaimReceiver {
    error InvalidConfig();
    error UnauthorizedMessage();
    error InvalidClaim();
    error ConflictingClaim();
    error InvalidMinimum();
    error InsufficientShares();
    error ReentrantCall();

    enum ClaimStatus {
        Unknown,
        Pending,
        Paid
    }
    enum SettlementResult {
        Unknown,
        Paid,
        WaitingForBridge,
        WaitingForLiquidity,
        UnsupportedBridgeConfig,
        Ready
    }

    uint256 public constant SETTLEMENT_GAS_LIMIT = 350_000;
    uint256 public constant REGISTRATION_GAS_RESERVE = 100_000;
    IHomeXDaiBridge public immutable homeBridge;
    IAMB public immutable homeAMB;
    ISavingsXDaiAdapter public immutable adapter;
    address public immutable sourceRouter;
    address public immutable foreignBridge;
    address public immutable bridgeImplementation;
    bytes32 public immutable bridgeImplementationCodeHash;

    struct StoredClaim {
        VaultClaimLib.Claim original;
        ClaimStatus status;
        uint256 minimumShares;
    }
    mapping(bytes32 => StoredClaim) private claims;
    bool private settling;

    event ClaimRegistered(
        bytes32 indexed claimId,
        address indexed payer,
        address indexed recipient,
        bytes32 bridgeNonce,
        uint256 amount,
        uint256 minShares
    );
    event ClaimPaid(
        bytes32 indexed claimId, address indexed recipient, uint256 amount, uint256 shares
    );
    event MinimumSharesLowered(bytes32 indexed claimId, uint256 minimumShares);
    event SettlementAttemptFailed(bytes32 indexed claimId);

    constructor(
        IHomeXDaiBridge homeBridge_,
        IAMB homeAMB_,
        ISavingsXDaiAdapter adapter_,
        address sourceRouter_,
        address foreignBridge_
    ) {
        if (
            block.chainid != 100 || address(homeBridge_).code.length == 0
                || address(homeAMB_).code.length == 0 || address(adapter_).code.length == 0
                || sourceRouter_ == address(0) || foreignBridge_ == address(0)
                || homeAMB_.sourceChainId() != 100 || homeAMB_.destinationChainId() != 1
                || homeBridge_.feeManagerContract() != address(0) || homeBridge_.decimalShift() != 0
        ) {
            revert InvalidConfig();
        }
        address implementation = homeBridge_.implementation();
        if (implementation.code.length == 0) revert InvalidConfig();
        homeBridge = homeBridge_;
        homeAMB = homeAMB_;
        adapter = adapter_;
        sourceRouter = sourceRouter_;
        foreignBridge = foreignBridge_;
        bridgeImplementation = implementation;
        bridgeImplementationCodeHash = implementation.codehash;
    }

    // shortcut: sponsor liquidity has no withdrawal path; design liabilities and delayed exits before accepting withdrawable LP capital
    receive() external payable { }

    function getClaim(bytes32 id)
        external
        view
        returns (VaultClaimLib.Claim memory original, ClaimStatus status, uint256 minimumShares)
    {
        StoredClaim storage c = claims[id];
        return (c.original, c.status, c.minimumShares);
    }

    function registerClaim(VaultClaimLib.Claim calldata original) external returns (bytes32 id) {
        if (settling) revert ReentrantCall();
        if (
            block.chainid != 100 || msg.sender != address(homeAMB)
                || homeAMB.messageSender() != sourceRouter || homeAMB.messageSourceChainId() != 1
        ) {
            revert UnauthorizedMessage();
        }
        if (
            original.payer == address(0) || original.recipient == address(0) || original.amount == 0
        ) {
            revert InvalidClaim();
        }
        id = VaultClaimLib.id(
            sourceRouter, foreignBridge, address(homeBridge), address(this), original.bridgeNonce
        );
        StoredClaim storage c = claims[id];
        if (c.status != ClaimStatus.Unknown) {
            if (keccak256(abi.encode(c.original)) != keccak256(abi.encode(original))) {
                revert ConflictingClaim();
            }
            return id;
        }
        c.original = original;
        c.status = ClaimStatus.Pending;
        c.minimumShares = original.minShares;
        emit ClaimRegistered(
            id,
            original.payer,
            original.recipient,
            original.bridgeNonce,
            original.amount,
            original.minShares
        );
        // EIP-150 overhead plus a parent reserve keeps failed conversion from erasing registration.
        if (gasleft() > SETTLEMENT_GAS_LIMIT + SETTLEMENT_GAS_LIMIT / 63 + REGISTRATION_GAS_RESERVE)
        {
            try this.settle{ gas: SETTLEMENT_GAS_LIMIT }(id) returns (SettlementResult, uint256) { }
            catch {
                emit SettlementAttemptFailed(id);
            }
        }
    }

    function settlementStatus(bytes32 id) public view returns (SettlementResult) {
        StoredClaim storage c = claims[id];
        if (c.status == ClaimStatus.Unknown) return SettlementResult.Unknown;
        if (c.status == ClaimStatus.Paid) return SettlementResult.Paid;
        if (!_supportedBridge()) return SettlementResult.UnsupportedBridgeConfig;
        bytes32 transferHash =
            keccak256(abi.encodePacked(address(this), c.original.amount, c.original.bridgeNonce));
        try homeBridge.numAffirmationsSigned(transferHash) returns (uint256 count) {
            try homeBridge.isAlreadyProcessed(count) returns (bool processed) {
                if (!processed) return SettlementResult.WaitingForBridge;
            } catch {
                return SettlementResult.UnsupportedBridgeConfig;
            }
        } catch {
            return SettlementResult.UnsupportedBridgeConfig;
        }
        if (address(this).balance < c.original.amount) return SettlementResult.WaitingForLiquidity;
        return SettlementResult.Ready;
    }

    function _supportedBridge() private view returns (bool) {
        if (block.chainid != 100 || bridgeImplementation.codehash != bridgeImplementationCodeHash) {
            return false;
        }
        try homeBridge.implementation() returns (address implementation) {
            if (implementation != bridgeImplementation) return false;
        } catch {
            return false;
        }
        try homeBridge.feeManagerContract() returns (address manager) {
            if (manager != address(0)) return false;
        } catch {
            return false;
        }
        try homeBridge.decimalShift() returns (int256 shift) {
            return shift == 0;
        } catch {
            return false;
        }
    }

    function settle(bytes32 id) external returns (SettlementResult result, uint256 shares) {
        if (settling) revert ReentrantCall();
        settling = true;
        result = settlementStatus(id);
        if (result == SettlementResult.Ready) {
            StoredClaim storage c = claims[id];
            c.status = ClaimStatus.Paid;
            shares = adapter.depositXDAI{ value: c.original.amount }(c.original.recipient);
            if (shares == 0 || shares < c.minimumShares) revert InsufficientShares();
            emit ClaimPaid(id, c.original.recipient, c.original.amount, shares);
            result = SettlementResult.Paid;
        }
        settling = false;
    }

    function lowerMinShares(bytes32 id, uint256 newMinimum) external {
        if (settling) revert ReentrantCall();
        StoredClaim storage c = claims[id];
        if (
            c.status != ClaimStatus.Pending || msg.sender != c.original.recipient
                || newMinimum > c.minimumShares
        ) {
            revert InvalidMinimum();
        }
        emit MinimumSharesLowered(id, newMinimum);
        c.minimumShares = newMinimum;
    }
}
