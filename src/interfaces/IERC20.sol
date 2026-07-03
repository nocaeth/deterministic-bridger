// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IERC20
/// @notice Minimal ERC-20 interface needed by the router and bridge mocks.
interface IERC20 {
    /// @notice Returns the token balance of an account.
    /// @param account Account to query.
    /// @return balance Token balance.
    function balanceOf(address account) external view returns (uint256 balance);

    /// @notice Sets `spender` allowance over the caller's tokens.
    /// @param spender Account allowed to spend tokens.
    /// @param amount Allowance amount.
    /// @return success True when approval succeeds.
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Transfers tokens from the caller to another account.
    /// @param to Token recipient.
    /// @param amount Token amount to transfer.
    /// @return success True when transfer succeeds.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Transfers tokens from one account to another using allowance.
    /// @param from Token owner.
    /// @param to Token recipient.
    /// @param amount Token amount to transfer.
    /// @return success True when transfer succeeds.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
