// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IXDaiBridge } from "./IXDaiBridge.sol";

/// @notice Ethereum bridge getters that bind one relay to one immutable claim.
interface INonceXDaiBridge is IXDaiBridge {
    /// @notice Returns the nonce used by the next relay.
    function nonce() external view returns (uint256);
    /// @notice Returns the token accepted by the bridge.
    function erc20token() external view returns (address);
    /// @notice Current proxy implementation, used to stop deposits after upgrades.
    function implementation() external view returns (address);
}
