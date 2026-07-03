// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "./interfaces/IERC20.sol";
import { IXDaiBridge } from "./interfaces/IXDaiBridge.sol";
import { DeterministicReceiverLib } from "./libraries/DeterministicReceiverLib.sol";
import { SafeERC20 } from "./libraries/SafeERC20.sol";

/// @title MainnetStablecoinBridgeRouter
/// @notice Bridges a configured mainnet stablecoin to a deterministic Gnosis receiver.
/// @dev The token and foreign bridge are deployment-configured and must be compatible with
///      `relayTokens(address,uint256)`. Receiver addresses are derived from `deterministicReceiver`.
contract MainnetStablecoinBridgeRouter {
    using SafeERC20 for IERC20;

    /// @notice Reverts when a bridge amount is zero.
    error InvalidAmount();

    /// @notice Reverts when constructor configuration contains a zero address.
    error InvalidConfig();

    /// @notice Reverts when the intended deterministic receiver is the zero address.
    error InvalidReceiver();

    /// @notice Emitted after tokens are handed to the configured foreign bridge.
    /// @param payer Mainnet account whose allowance and balance were spent.
    /// @param deterministicReceiver Address that determines the Gnosis receiver and sDAI owner.
    /// @param gnosisReceiver Deterministic receiver address on Gnosis.
    /// @param amount Mainnet token amount bridged.
    event BridgeRequested(
        address indexed payer,
        address indexed deterministicReceiver,
        address indexed gnosisReceiver,
        uint256 amount
    );

    /// @notice Mainnet stablecoin pulled from the payer before bridging.
    IERC20 public immutable mainnetToken;

    /// @notice Foreign bridge that accepts `mainnetToken` through `relayTokens(address,uint256)`.
    IXDaiBridge public immutable foreignBridge;

    /// @notice Gnosis factory used in deterministic receiver prediction.
    address public immutable gnosisFactory;

    /// @notice Gnosis singleton implementation used in deterministic receiver prediction.
    address public immutable gnosisSingleton;

    /// @notice Creates the mainnet bridge router.
    /// @param mainnetToken_ Mainnet token transferred from payers.
    /// @param foreignBridge_ Bridge configured for `mainnetToken_`.
    /// @param gnosisFactory_ Gnosis receiver factory address.
    /// @param gnosisSingleton_ Gnosis receiver singleton implementation address.
    constructor(
        IERC20 mainnetToken_,
        IXDaiBridge foreignBridge_,
        address gnosisFactory_,
        address gnosisSingleton_
    ) {
        if (
            address(mainnetToken_) == address(0) || address(foreignBridge_) == address(0)
                || gnosisFactory_ == address(0) || gnosisSingleton_ == address(0)
        ) {
            revert InvalidConfig();
        }

        mainnetToken = mainnetToken_;
        foreignBridge = foreignBridge_;
        gnosisFactory = gnosisFactory_;
        gnosisSingleton = gnosisSingleton_;
    }

    /// @notice Predicts the Gnosis receiver for a deterministic receiver.
    /// @param deterministicReceiver Address that owns eventual sDAI shares.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    function receiverFor(address deterministicReceiver)
        public
        view
        returns (address gnosisReceiver)
    {
        gnosisReceiver = DeterministicReceiverLib.predict(
            gnosisFactory, gnosisSingleton, deterministicReceiver
        );
    }

    /// @notice Bridges tokens for the caller as the deterministic receiver.
    /// @param amount Mainnet token amount to bridge.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    function bridge(uint256 amount) external returns (address gnosisReceiver) {
        gnosisReceiver = _bridge(msg.sender, amount);
    }

    /// @notice Bridges caller-funded tokens for a separate deterministic receiver.
    /// @param deterministicReceiver Address that determines the Gnosis receiver and sDAI owner.
    /// @param amount Mainnet token amount to bridge.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    function bridgeTo(address deterministicReceiver, uint256 amount)
        external
        returns (address gnosisReceiver)
    {
        gnosisReceiver = _bridge(deterministicReceiver, amount);
    }

    /// @notice Transfers tokens from the payer and relays them to the deterministic receiver.
    /// @param deterministicReceiver Address used to derive the Gnosis receiver.
    /// @param amount Mainnet token amount to bridge.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    function _bridge(address deterministicReceiver, uint256 amount)
        private
        returns (address gnosisReceiver)
    {
        if (deterministicReceiver == address(0)) revert InvalidReceiver();
        if (amount == 0) revert InvalidAmount();

        gnosisReceiver = receiverFor(deterministicReceiver);
        mainnetToken.safeTransferFrom(msg.sender, address(this), amount);
        mainnetToken.safeApprove(address(foreignBridge), amount);
        foreignBridge.relayTokens(gnosisReceiver, amount);

        emit BridgeRequested(msg.sender, deterministicReceiver, gnosisReceiver, amount);
    }
}
