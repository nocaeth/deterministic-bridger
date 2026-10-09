// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "./IERC20.sol";

/// @notice ERC-4626 operations used to redeem sUSDS into its underlying USDS.
interface IERC4626 is IERC20 {
    /// @notice Returns the underlying token redeemed by this vault.
    function asset() external view returns (address);

    /// @notice Redeems vault shares for assets.
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);
}
