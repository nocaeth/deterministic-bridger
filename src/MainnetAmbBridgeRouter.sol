// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "./interfaces/IERC20.sol";
import { IERC4626 } from "./interfaces/IERC4626.sol";
import { IAMB, IAMBClaimReceiver } from "./interfaces/IAMB.sol";
import { INonceXDaiBridge } from "./interfaces/INonceXDaiBridge.sol";
import { ChainConstants } from "./libraries/ChainConstants.sol";
import { VaultClaimLib } from "./libraries/VaultClaimLib.sol";
import { SafeERC20 } from "./libraries/SafeERC20.sol";

/// @notice Atomically bridges caller USDS and sends its immutable payout claim through AMB.
contract MainnetAmbBridgeRouter {
    using SafeERC20 for IERC20;

    error InvalidConfig();
    error InvalidReceiver();
    error InvalidAmount();
    error FundingMismatch();
    error RelayMismatch();
    error UnsupportedBridge();
    error UnknownClaim();
    error ReentrantCall();

    uint256 public constant CLAIM_GAS_LIMIT = 700_000;
    IERC20 public immutable mainnetToken;
    IERC4626 public immutable savingsUSDS;
    INonceXDaiBridge public immutable foreignBridge;
    IAMB public immutable foreignAMB;
    address public immutable homeBridge;
    address public immutable gnosisVault;
    address public immutable bridgeImplementation;
    bytes32 public immutable bridgeImplementationCodeHash;

    mapping(bytes32 => VaultClaimLib.Claim) private claims;
    bool private entered;

    event ClaimBridged(
        bytes32 indexed claimId,
        address indexed payer,
        address indexed recipient,
        bytes32 bridgeNonce,
        uint256 amount,
        uint256 minShares,
        bytes32 ambMessageId
    );
    event ClaimMessageSent(bytes32 indexed claimId, bytes32 indexed ambMessageId);

    constructor(
        INonceXDaiBridge foreignBridge_,
        IAMB foreignAMB_,
        address homeBridge_,
        address gnosisVault_
    ) {
        if (
            block.chainid != 1 || address(foreignBridge_).code.length == 0
                || address(foreignAMB_).code.length == 0 || homeBridge_ == address(0)
                || gnosisVault_ == address(0) || ChainConstants.ETHEREUM_USDS.code.length == 0
                || ChainConstants.ETHEREUM_SUSDS.code.length == 0
                || foreignBridge_.erc20token() != ChainConstants.ETHEREUM_USDS
                || foreignAMB_.sourceChainId() != 1 || foreignAMB_.destinationChainId() != 100
                || foreignAMB_.maxGasPerTx() < CLAIM_GAS_LIMIT
        ) revert InvalidConfig();

        address implementation = foreignBridge_.implementation();
        if (implementation.code.length == 0) revert InvalidConfig();
        mainnetToken = IERC20(ChainConstants.ETHEREUM_USDS);
        savingsUSDS = IERC4626(ChainConstants.ETHEREUM_SUSDS);
        foreignBridge = foreignBridge_;
        foreignAMB = foreignAMB_;
        homeBridge = homeBridge_;
        gnosisVault = gnosisVault_;
        bridgeImplementation = implementation;
        bridgeImplementationCodeHash = implementation.codehash;
    }

    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    function bridge(uint256 amount, uint256 minShares)
        external
        nonReentrant
        returns (bytes32 claimId, uint256 assets)
    {
        return _bridgeUSDS(msg.sender, amount, minShares);
    }

    function bridgeTo(address recipient, uint256 amount, uint256 minShares)
        external
        nonReentrant
        returns (bytes32 claimId, uint256 assets)
    {
        return _bridgeUSDS(recipient, amount, minShares);
    }

    function bridgeSavingsUSDS(uint256 shares, uint256 minShares)
        external
        nonReentrant
        returns (bytes32 claimId, uint256 assets)
    {
        return _bridgeSavings(msg.sender, shares, minShares);
    }

    function bridgeSavingsUSDSTo(address recipient, uint256 shares, uint256 minShares)
        external
        nonReentrant
        returns (bytes32 claimId, uint256 assets)
    {
        return _bridgeSavings(recipient, shares, minShares);
    }

    function getClaim(bytes32 claimId) external view returns (VaultClaimLib.Claim memory) {
        return claims[claimId];
    }

    /// @notice Redelivers an existing claim; it never redeems or relays tokens again.
    function resendClaim(bytes32 claimId) external nonReentrant returns (bytes32 ambMessageId) {
        if (claims[claimId].payer == address(0)) revert UnknownClaim();
        return _sendClaim(claimId, claims[claimId]);
    }

    function _validate(address recipient, uint256 amount) private view {
        if (recipient == address(0)) revert InvalidReceiver();
        if (amount == 0) revert InvalidAmount();
        if (
            block.chainid != 1 || foreignBridge.implementation() != bridgeImplementation
                || bridgeImplementation.codehash != bridgeImplementationCodeHash
                || foreignBridge.erc20token() != address(mainnetToken)
        ) revert UnsupportedBridge();
    }

    function _bridgeUSDS(address recipient, uint256 amount, uint256 minShares)
        private
        returns (bytes32 claimId, uint256 assets)
    {
        _validate(recipient, amount);
        uint256 beforeBalance = mainnetToken.balanceOf(address(this));
        mainnetToken.safeTransferFrom(msg.sender, address(this), amount);
        assets = mainnetToken.balanceOf(address(this)) - beforeBalance;
        if (assets != amount) revert FundingMismatch();
        claimId = _relay(recipient, assets, minShares);
    }

    function _bridgeSavings(address recipient, uint256 shares, uint256 minShares)
        private
        returns (bytes32 claimId, uint256 assets)
    {
        _validate(recipient, shares);
        uint256 beforeBalance = mainnetToken.balanceOf(address(this));
        uint256 reported = savingsUSDS.redeem(shares, address(this), msg.sender);
        assets = mainnetToken.balanceOf(address(this)) - beforeBalance;
        if (assets != reported) revert FundingMismatch();
        if (assets == 0) revert InvalidAmount();
        claimId = _relay(recipient, assets, minShares);
    }

    function _relay(address recipient, uint256 amount, uint256 minShares)
        private
        returns (bytes32 claimId)
    {
        uint256 nonce = foreignBridge.nonce();
        uint256 beforeRouter = mainnetToken.balanceOf(address(this));
        uint256 beforeBridge = mainnetToken.balanceOf(address(foreignBridge));
        mainnetToken.safeApprove(address(foreignBridge), 0);
        mainnetToken.safeApprove(address(foreignBridge), amount);
        foreignBridge.relayTokens(gnosisVault, amount);
        if (
            foreignBridge.nonce() != nonce + 1
                || mainnetToken.balanceOf(address(this)) != beforeRouter - amount
                || mainnetToken.balanceOf(address(foreignBridge)) != beforeBridge + amount
        ) revert RelayMismatch();
        mainnetToken.safeApprove(address(foreignBridge), 0);
        claimId = VaultClaimLib.id(
            address(this), address(foreignBridge), homeBridge, gnosisVault, bytes32(nonce)
        );
        VaultClaimLib.Claim memory claim =
            VaultClaimLib.Claim(bytes32(nonce), msg.sender, recipient, amount, minShares);
        claims[claimId] = claim;
        bytes32 messageId = _sendClaim(claimId, claim);
        emit ClaimBridged(
            claimId, msg.sender, recipient, bytes32(nonce), amount, minShares, messageId
        );
    }

    function _sendClaim(bytes32 claimId, VaultClaimLib.Claim memory claim)
        private
        returns (bytes32 messageId)
    {
        if (
            block.chainid != 1 || foreignAMB.sourceChainId() != 1
                || foreignAMB.destinationChainId() != 100
        ) {
            revert InvalidConfig();
        }
        messageId = foreignAMB.requireToPassMessage(
            gnosisVault, abi.encodeCall(IAMBClaimReceiver.registerClaim, (claim)), CLAIM_GAS_LIMIT
        );
        if (messageId == bytes32(0)) revert InvalidConfig();
        emit ClaimMessageSent(claimId, messageId);
    }
}
