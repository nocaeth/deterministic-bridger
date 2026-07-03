// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { SavingsXDaiReceiver } from "./SavingsXDaiReceiver.sol";
import { DeterministicReceiverLib } from "./libraries/DeterministicReceiverLib.sol";

/// @title SavingsXDaiReceiverFactory
/// @notice Deploys deterministic Savings xDAI receivers derived from deterministic receivers.
/// @dev The watchtower is permissionless: anyone can deploy a receiver and trigger conversion.
contract SavingsXDaiReceiverFactory {
    /// @notice Reverts when the singleton address is zero or has no code.
    error InvalidSingleton();

    /// @notice Emitted when a deterministic receiver clone is deployed.
    /// @param deterministicReceiver Address used for address derivation and sDAI delivery.
    /// @param receiver Deterministic Gnosis receiver clone.
    event Deployed(address indexed deterministicReceiver, address indexed receiver);

    /// @notice Singleton implementation cloned for each deterministic receiver.
    address public immutable singleton;

    /// @notice Creates the deterministic receiver factory.
    /// @param singleton_ Deployed `SavingsXDaiReceiver` implementation on Gnosis.
    constructor(address singleton_) {
        if (singleton_ == address(0) || singleton_.code.length == 0) revert InvalidSingleton();
        singleton = singleton_;
    }

    /// @notice Predicts the receiver address for a deterministic receiver.
    /// @param deterministicReceiver Address that owns the eventual sDAI shares.
    /// @return receiver Deterministic Gnosis receiver clone address.
    function predict(address deterministicReceiver) public view returns (address receiver) {
        receiver = DeterministicReceiverLib.predict(address(this), singleton, deterministicReceiver);
    }

    /// @notice Deploys the deterministic receiver for a deterministic receiver if needed.
    /// @dev Setup immediately calls conversion, which returns cleanly when no xDAI is present.
    /// @param deterministicReceiver Address used for address derivation and sDAI delivery.
    /// @return receiver Deployed deterministic Gnosis receiver clone.
    function deploy(address deterministicReceiver) public returns (address receiver) {
        (receiver,,) = _deploy(deterministicReceiver);
    }

    /// @notice Deploys the receiver if needed and converts its full xDAI balance to sDAI.
    /// @dev Permissionless watchtower entry point. Adapter failures leave xDAI in the receiver.
    /// @param deterministicReceiver Address used for address derivation and sDAI delivery.
    /// @return receiver Deployed deterministic Gnosis receiver clone.
    /// @return shares sDAI shares reported by the adapter, or zero when there is no xDAI.
    function deployAndConvert(address deterministicReceiver)
        external
        returns (address receiver, uint256 shares)
    {
        bool deployed;
        (receiver, shares, deployed) = _deploy(deterministicReceiver);
        if (!deployed) {
            shares = SavingsXDaiReceiver(payable(receiver)).convertToSavingsXDai();
        }
    }

    /// @notice Deploys and initializes a new receiver, returning conversion results if prefunded.
    /// @param deterministicReceiver Address used for address derivation and sDAI delivery.
    /// @return receiver Deterministic Gnosis receiver clone.
    /// @return shares sDAI shares from automatic conversion during setup, if any.
    /// @return deployed True when a new clone was deployed.
    function _deploy(address deterministicReceiver)
        private
        returns (address receiver, uint256 shares, bool deployed)
    {
        receiver = predict(deterministicReceiver);
        if (receiver.code.length != 0) return (receiver, 0, false);

        receiver = DeterministicReceiverLib.deploy(singleton, deterministicReceiver);
        SavingsXDaiReceiver savingsReceiver = SavingsXDaiReceiver(payable(receiver));
        savingsReceiver.setUp(deterministicReceiver);
        emit Deployed(deterministicReceiver, receiver);
        deployed = true;
        shares = savingsReceiver.convertToSavingsXDai();
    }
}
