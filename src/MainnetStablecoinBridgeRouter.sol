// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "./interfaces/IERC20.sol";
import { IERC4626 } from "./interfaces/IERC4626.sol";
import { IXDaiBridge } from "./interfaces/IXDaiBridge.sol";
import { ChainConstants } from "./libraries/ChainConstants.sol";
import { DeterministicReceiverLib } from "./libraries/DeterministicReceiverLib.sol";
import { SafeERC20 } from "./libraries/SafeERC20.sol";

/// @title MainnetStablecoinBridgeRouter
/// @notice Bridges mainnet USDS or sUSDS to a deterministic Gnosis receiver.
/// @dev USDS is hardcoded as the canonical xDai bridge token. sUSDS is hardcoded as an
///      ERC-4626 input token and redeemed into USDS before bridging.
contract MainnetStablecoinBridgeRouter {
    using SafeERC20 for IERC20;

    /// @notice Mainnet USDS token pulled from payers before bridging.
    address public constant MAINNET_TOKEN = ChainConstants.ETHEREUM_USDS;

    /// @notice Mainnet sUSDS ERC-4626 vault pulled from payers and redeemed before bridging.
    address public constant SAVINGS_USDS = ChainConstants.ETHEREUM_SUSDS;

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
    /// @param amount USDS amount bridged.
    event BridgeRequested(
        address indexed payer,
        address indexed deterministicReceiver,
        address indexed gnosisReceiver,
        uint256 amount
    );

    /// @notice Mainnet USDS pulled from the payer before bridging.
    IERC20 public immutable mainnetToken;

    /// @notice Mainnet sUSDS pulled from the payer and redeemed into USDS before bridging.
    IERC4626 public immutable savingsUSDS;

    /// @notice Foreign bridge that accepts `mainnetToken` through `relayTokens(address,uint256)`.
    IXDaiBridge public immutable foreignBridge;

    /// @notice Gnosis factory used in deterministic receiver prediction.
    address public immutable gnosisFactory;

    /// @notice Gnosis singleton implementation used in deterministic receiver prediction.
    address public immutable gnosisSingleton;

    /// @notice Creates the mainnet bridge router.
    /// @param foreignBridge_ Bridge configured for hardcoded USDS.
    /// @param gnosisFactory_ Gnosis receiver factory address.
    /// @param gnosisSingleton_ Gnosis receiver singleton implementation address.
    constructor(IXDaiBridge foreignBridge_, address gnosisFactory_, address gnosisSingleton_) {
        if (
            address(foreignBridge_) == address(0) || gnosisFactory_ == address(0)
                || gnosisSingleton_ == address(0)
        ) {
            revert InvalidConfig();
        }

        mainnetToken = IERC20(MAINNET_TOKEN);
        savingsUSDS = IERC4626(SAVINGS_USDS);
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

    /// @notice Bridges USDS for the caller as the deterministic receiver.
    /// @param amount USDS amount to bridge.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    function bridge(uint256 amount) external returns (address gnosisReceiver) {
        gnosisReceiver = _bridgeUSDS(msg.sender, amount);
    }

    /// @notice Bridges caller-funded USDS for a separate deterministic receiver.
    /// @param deterministicReceiver Address that determines the Gnosis receiver and sDAI owner.
    /// @param amount USDS amount to bridge.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    function bridgeTo(address deterministicReceiver, uint256 amount)
        external
        returns (address gnosisReceiver)
    {
        gnosisReceiver = _bridgeUSDS(deterministicReceiver, amount);
    }

    /// @notice Redeems caller sUSDS into USDS and bridges it for the caller.
    /// @param shares sUSDS shares to redeem.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    /// @return amount USDS amount bridged after redemption.
    function bridgeSavingsUSDS(uint256 shares)
        external
        returns (address gnosisReceiver, uint256 amount)
    {
        (gnosisReceiver, amount) = _bridgeSavingsUSDS(msg.sender, shares);
    }

    /// @notice Redeems caller sUSDS into USDS and bridges it for a separate receiver.
    /// @param deterministicReceiver Address that determines the Gnosis receiver and sDAI owner.
    /// @param shares sUSDS shares to redeem.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    /// @return amount USDS amount bridged after redemption.
    function bridgeSavingsUSDSTo(address deterministicReceiver, uint256 shares)
        external
        returns (address gnosisReceiver, uint256 amount)
    {
        (gnosisReceiver, amount) = _bridgeSavingsUSDS(deterministicReceiver, shares);
    }

    /// @notice Transfers USDS from the payer and relays it to the deterministic receiver.
    /// @param deterministicReceiver Address used to derive the Gnosis receiver.
    /// @param amount USDS amount to bridge.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    function _bridgeUSDS(address deterministicReceiver, uint256 amount)
        private
        returns (address gnosisReceiver)
    {
        gnosisReceiver = _validateReceiverAndAmount(deterministicReceiver, amount);
        mainnetToken.safeTransferFrom(msg.sender, address(this), amount);
        _relay(deterministicReceiver, gnosisReceiver, amount);
    }

    /// @notice Redeems sUSDS from the payer, then relays the received USDS.
    /// @param deterministicReceiver Address used to derive the Gnosis receiver.
    /// @param shares sUSDS shares to redeem.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    /// @return amount USDS amount bridged after redemption.
    function _bridgeSavingsUSDS(address deterministicReceiver, uint256 shares)
        private
        returns (address gnosisReceiver, uint256 amount)
    {
        gnosisReceiver = _validateReceiverAndAmount(deterministicReceiver, shares);
        amount = savingsUSDS.redeem(shares, address(this), msg.sender);
        if (amount == 0) revert InvalidAmount();
        _relay(deterministicReceiver, gnosisReceiver, amount);
    }

    /// @notice Validates bridge input and predicts the Gnosis receiver.
    /// @param deterministicReceiver Address used to derive the Gnosis receiver.
    /// @param amount Token amount or shares supplied by the caller.
    /// @return gnosisReceiver Deterministic receiver address on Gnosis.
    function _validateReceiverAndAmount(address deterministicReceiver, uint256 amount)
        private
        view
        returns (address gnosisReceiver)
    {
        if (deterministicReceiver == address(0)) revert InvalidReceiver();
        if (amount == 0) revert InvalidAmount();
        gnosisReceiver = receiverFor(deterministicReceiver);
    }

    /// @notice Approves and relays the router's USDS balance to the bridge.
    /// @param deterministicReceiver Address used to derive the Gnosis receiver.
    /// @param gnosisReceiver Deterministic receiver address on Gnosis.
    /// @param amount USDS amount to bridge.
    function _relay(address deterministicReceiver, address gnosisReceiver, uint256 amount) private {
        mainnetToken.safeApprove(address(foreignBridge), 0);
        mainnetToken.safeApprove(address(foreignBridge), amount);
        foreignBridge.relayTokens(gnosisReceiver, amount);
        mainnetToken.safeApprove(address(foreignBridge), 0);
        emit BridgeRequested(msg.sender, deterministicReceiver, gnosisReceiver, amount);
    }
}
