// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Minimal foreign bridge interface used by the mainnet router.
interface IXDaiBridge {
    /// @notice Relays the caller-funded token amount to a receiver on Gnosis.
    function relayTokens(address receiver, uint256 amount) external;
}
