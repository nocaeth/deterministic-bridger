// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IXDaiBridge
/// @notice Minimal foreign bridge interface used by the mainnet router.
interface IXDaiBridge {
    /// @notice Relays the caller-funded token amount to a receiver on Gnosis.
    /// @param receiver Gnosis address that receives bridged native xDAI.
    /// @param amount Mainnet token amount to bridge.
    function relayTokens(address receiver, uint256 amount) external;
}
