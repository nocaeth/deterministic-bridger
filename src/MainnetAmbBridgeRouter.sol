// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "./interfaces/IERC20.sol";
import { IERC4626 } from "./interfaces/IERC4626.sol";
import { IAMB, IAMBClaimReceiver } from "./interfaces/IAMB.sol";
import { INonceXDaiBridge } from "./interfaces/INonceXDaiBridge.sol";
import { ChainConstants } from "./libraries/ChainConstants.sol";
import { VaultClaimLib } from "./libraries/VaultClaimLib.sol";
import { SafeERC20 } from "./libraries/SafeERC20.sol";
import { ReentrancyGuard } from "./utils/ReentrancyGuard.sol";

/// @notice Atomically bridges caller USDS and sends its immutable payout claim through AMB.
contract MainnetAmbBridgeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidConfig();
    error InvalidReceiver();
    error InvalidAmount();
    error FundingMismatch();
    error RelayMismatch();
    error UnsupportedBridge();
    error UnknownClaim();

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
            block.chainid != ChainConstants.ETHEREUM_CHAIN_ID
                || address(foreignBridge_).code.length == 0 || address(foreignAMB_).code.length == 0
                || homeBridge_ == address(0) || gnosisVault_ == address(0)
                || ChainConstants.ETHEREUM_USDS.code.length == 0
                || ChainConstants.ETHEREUM_SUSDS.code.length == 0
                || IERC4626(ChainConstants.ETHEREUM_SUSDS).asset() != ChainConstants.ETHEREUM_USDS
                || foreignBridge_.erc20token() != ChainConstants.ETHEREUM_USDS
                || foreignAMB_.sourceChainId() != ChainConstants.ETHEREUM_CHAIN_ID
                || foreignAMB_.destinationChainId() != ChainConstants.GNOSIS_CHAIN_ID
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

    /// @notice Bridges caller USDS and requests sDAI for the caller on Gnosis.
    /// @param minShares Minimum sDAI shares required to settle the claim.
    function bridge(uint256 amount, uint256 minShares)
        external
        nonReentrant
        returns (bytes32 claimId, uint256 assets)
    {
        return _bridgeUSDS(msg.sender, amount, minShares);
    }

    /// @notice Bridges caller USDS and requests sDAI for `recipient` on Gnosis.
    /// @param minShares Minimum sDAI shares required to settle the claim.
    function bridgeTo(address recipient, uint256 amount, uint256 minShares)
        external
        nonReentrant
        returns (bytes32 claimId, uint256 assets)
    {
        return _bridgeUSDS(recipient, amount, minShares);
    }

    /// @notice Redeems caller sUSDS, bridges its USDS, and requests sDAI for the caller.
    /// @param shares sUSDS input shares to redeem.
    /// @param minShares Minimum sDAI output shares required to settle the claim.
    function bridgeSavingsUSDS(uint256 shares, uint256 minShares)
        external
        nonReentrant
        returns (bytes32 claimId, uint256 assets)
    {
        return _bridgeSavings(msg.sender, shares, minShares);
    }

    /// @notice Redeems caller sUSDS and requests sDAI for `recipient` on Gnosis.
    /// @param shares sUSDS input shares to redeem.
    /// @param minShares Minimum sDAI output shares required to settle the claim.
    function bridgeSavingsUSDSTo(address recipient, uint256 shares, uint256 minShares)
        external
        nonReentrant
        returns (bytes32 claimId, uint256 assets)
    {
        return _bridgeSavings(recipient, shares, minShares);
    }

    /// @notice Returns the immutable claim, or zero fields for an unknown claim.
    function getClaim(bytes32 claimId) external view returns (VaultClaimLib.Claim memory) {
        return claims[claimId];
    }

    /// @notice Redelivers an existing claim; it never redeems or relays tokens again.
    function resendClaim(bytes32 claimId) external nonReentrant returns (bytes32 ambMessageId) {
        if (claims[claimId].payer == address(0)) revert UnknownClaim();
        return _sendClaim(claimId, claims[claimId]);
    }

    function _validateRequest(address recipient, uint256 amount) private view {
        if (recipient == address(0)) revert InvalidReceiver();
        if (amount == 0) revert InvalidAmount();
        if (
            block.chainid != ChainConstants.ETHEREUM_CHAIN_ID
                || foreignBridge.implementation() != bridgeImplementation
                || bridgeImplementation.codehash != bridgeImplementationCodeHash
                || foreignBridge.erc20token() != address(mainnetToken)
        ) revert UnsupportedBridge();
    }

    function _bridgeUSDS(address recipient, uint256 amount, uint256 minShares)
        private
        returns (bytes32 claimId, uint256 assets)
    {
        _validateRequest(recipient, amount);
        uint256 balanceBefore = mainnetToken.balanceOf(address(this));
        mainnetToken.safeTransferFrom(msg.sender, address(this), amount);
        assets = mainnetToken.balanceOf(address(this)) - balanceBefore;
        if (assets != amount) revert FundingMismatch();
        claimId = _relayAndSendClaim(recipient, assets, minShares);
    }

    function _bridgeSavings(address recipient, uint256 shares, uint256 minShares)
        private
        returns (bytes32 claimId, uint256 assets)
    {
        _validateRequest(recipient, shares);
        uint256 balanceBefore = mainnetToken.balanceOf(address(this));
        uint256 reportedAssets = savingsUSDS.redeem(shares, address(this), msg.sender);
        assets = mainnetToken.balanceOf(address(this)) - balanceBefore;
        if (assets != reportedAssets) revert FundingMismatch();
        if (assets == 0) revert InvalidAmount();
        claimId = _relayAndSendClaim(recipient, assets, minShares);
    }

    function _relayAndSendClaim(address recipient, uint256 amount, uint256 minShares)
        private
        returns (bytes32 claimId)
    {
        uint256 bridgeNonce = foreignBridge.nonce();
        uint256 routerBalanceBefore = mainnetToken.balanceOf(address(this));
        uint256 bridgeBalanceBefore = mainnetToken.balanceOf(address(foreignBridge));
        mainnetToken.safeApprove(address(foreignBridge), 0);
        mainnetToken.safeApprove(address(foreignBridge), amount);
        foreignBridge.relayTokens(gnosisVault, amount);
        if (
            foreignBridge.nonce() != bridgeNonce + 1
                || mainnetToken.balanceOf(address(this)) != routerBalanceBefore - amount
                || mainnetToken.balanceOf(address(foreignBridge)) != bridgeBalanceBefore + amount
        ) revert RelayMismatch();
        mainnetToken.safeApprove(address(foreignBridge), 0);
        claimId = VaultClaimLib.id(
            address(this), address(foreignBridge), homeBridge, gnosisVault, bytes32(bridgeNonce)
        );
        VaultClaimLib.Claim memory claim =
            VaultClaimLib.Claim(bytes32(bridgeNonce), msg.sender, recipient, amount, minShares);
        claims[claimId] = claim;
        bytes32 messageId = _sendClaim(claimId, claim);
        emit ClaimBridged(
            claimId, msg.sender, recipient, bytes32(bridgeNonce), amount, minShares, messageId
        );
    }

    function _sendClaim(bytes32 claimId, VaultClaimLib.Claim memory claim)
        private
        returns (bytes32 messageId)
    {
        if (
            block.chainid != ChainConstants.ETHEREUM_CHAIN_ID
                || foreignAMB.sourceChainId() != ChainConstants.ETHEREUM_CHAIN_ID
                || foreignAMB.destinationChainId() != ChainConstants.GNOSIS_CHAIN_ID
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
