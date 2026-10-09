// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice ERC-20 operations used by this protocol.
interface IERC20 {
    /// @notice Returns the token balance of an account.
    function balanceOf(address account) external view returns (uint256 balance);

    /// @notice Sets `spender` allowance over the caller's tokens.
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Transfers tokens from the caller to another account.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Transfers tokens from one account to another using allowance.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
