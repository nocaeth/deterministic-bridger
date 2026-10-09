// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IAMB, IAMBClaimReceiver } from "./interfaces/IAMB.sol";
import { IHomeXDaiBridge } from "./interfaces/IHomeXDaiBridge.sol";
import { ISavingsXDaiAdapter } from "./interfaces/ISavingsXDaiAdapter.sol";
import { VaultClaimLib } from "./libraries/VaultClaimLib.sol";
import { ReentrancyGuard } from "./utils/ReentrancyGuard.sol";
import { ChainConstants } from "./libraries/ChainConstants.sol";

/// @notice Registers AMB claims and settles executed canonical xDAI transfers into sDAI.
contract SavingsXDaiSettlementVault is IAMBClaimReceiver, ReentrancyGuard {
    error InvalidConfig();
    error UnauthorizedMessage();
    error InvalidClaim();
    error ConflictingClaim();
    error InvalidMinimum();
    error InsufficientShares();

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
            block.chainid != ChainConstants.GNOSIS_CHAIN_ID || address(homeBridge_).code.length == 0
                || address(homeAMB_).code.length == 0 || address(adapter_).code.length == 0
                || sourceRouter_ == address(0) || foreignBridge_ == address(0)
                || homeAMB_.sourceChainId() != ChainConstants.GNOSIS_CHAIN_ID
                || homeAMB_.destinationChainId() != ChainConstants.ETHEREUM_CHAIN_ID
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

    /// @notice Accepts permanent sponsor funding; this contract has no withdrawal function.
    receive() external payable { }

    /// @notice Returns the immutable payload, payment state, and current settlement minimum.
    function getClaim(bytes32 id)
        external
        view
        returns (VaultClaimLib.Claim memory original, ClaimStatus status, uint256 minimumShares)
    {
        StoredClaim storage storedClaim = claims[id];
        return (storedClaim.original, storedClaim.status, storedClaim.minimumShares);
    }

    /// @notice Registers a source-router claim authenticated by the configured AMB.
    /// @dev An identical replay preserves payment state and any lowered minimum.
    function registerClaim(VaultClaimLib.Claim calldata original) external returns (bytes32 id) {
        _requireNotEntered();
        if (
            block.chainid != ChainConstants.GNOSIS_CHAIN_ID || msg.sender != address(homeAMB)
                || homeAMB.messageSender() != sourceRouter
                || homeAMB.messageSourceChainId() != ChainConstants.ETHEREUM_CHAIN_ID
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
        StoredClaim storage storedClaim = claims[id];
        if (storedClaim.status != ClaimStatus.Unknown) {
            if (keccak256(abi.encode(storedClaim.original)) != keccak256(abi.encode(original))) {
                revert ConflictingClaim();
            }
            return id;
        }
        storedClaim.original = original;
        storedClaim.status = ClaimStatus.Pending;
        storedClaim.minimumShares = original.minShares;
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

    /// @notice Reports whether a claim can settle under the supported bridge configuration.
    function settlementStatus(bytes32 id) public view returns (SettlementResult) {
        StoredClaim storage storedClaim = claims[id];
        if (storedClaim.status == ClaimStatus.Unknown) return SettlementResult.Unknown;
        if (storedClaim.status == ClaimStatus.Paid) return SettlementResult.Paid;
        if (!_supportedBridge()) return SettlementResult.UnsupportedBridgeConfig;
        bytes32 transferHash = keccak256(
            abi.encodePacked(
                address(this), storedClaim.original.amount, storedClaim.original.bridgeNonce
            )
        );
        try homeBridge.numAffirmationsSigned(transferHash) returns (uint256 count) {
            try homeBridge.isAlreadyProcessed(count) returns (bool processed) {
                if (!processed) return SettlementResult.WaitingForBridge;
            } catch {
                return SettlementResult.UnsupportedBridgeConfig;
            }
        } catch {
            return SettlementResult.UnsupportedBridgeConfig;
        }
        if (address(this).balance < storedClaim.original.amount) {
            return SettlementResult.WaitingForLiquidity;
        }
        return SettlementResult.Ready;
    }

    function _supportedBridge() private view returns (bool) {
        if (
            block.chainid != ChainConstants.GNOSIS_CHAIN_ID
                || bridgeImplementation.codehash != bridgeImplementationCodeHash
        ) {
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

    /// @notice Pays a ready claim once; waiting, unknown, and paid claims are no-ops.
    /// @dev Adapter failure or insufficient shares reverts the payment and preserves the claim.
    function settle(bytes32 id)
        external
        nonReentrant
        returns (SettlementResult result, uint256 shares)
    {
        result = settlementStatus(id);
        if (result == SettlementResult.Ready) {
            StoredClaim storage storedClaim = claims[id];
            storedClaim.status = ClaimStatus.Paid;
            shares = adapter.depositXDAI{ value: storedClaim.original.amount }(
                storedClaim.original.recipient
            );
            if (shares == 0 || shares < storedClaim.minimumShares) revert InsufficientShares();
            emit ClaimPaid(id, storedClaim.original.recipient, storedClaim.original.amount, shares);
            result = SettlementResult.Paid;
        }
    }

    /// @notice Allows only the pending claim's recipient to lower its settlement minimum.
    function lowerMinShares(bytes32 id, uint256 newMinimum) external {
        _requireNotEntered();
        StoredClaim storage storedClaim = claims[id];
        if (
            storedClaim.status != ClaimStatus.Pending
                || msg.sender != storedClaim.original.recipient
                || newMinimum > storedClaim.minimumShares
        ) {
            revert InvalidMinimum();
        }
        emit MinimumSharesLowered(id, newMinimum);
        storedClaim.minimumShares = newMinimum;
    }
}
