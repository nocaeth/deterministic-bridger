// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "./IERC20.sol";

/// @title IERC4626
/// @notice Minimal ERC-4626 interface needed to redeem sUSDS into USDS.
interface IERC4626 is IERC20 {
    /// @notice Redeems vault shares for assets.
    /// @param shares Vault shares to redeem.
    /// @param receiver Account that receives the underlying asset.
    /// @param owner Account whose shares are burned.
    /// @return assets Amount of underlying asset received.
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);
}
