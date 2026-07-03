// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @title SafeERC20
/// @notice Minimal ERC-20 call wrappers that support tokens with or without boolean returns.
library SafeERC20 {
    /// @notice Reverts when a token call reverts or returns `false`.
    error SafeERC20CallFailed();

    /// @notice Safely approves a spender for a token amount.
    /// @param token ERC-20 token to call.
    /// @param spender Account allowed to spend tokens.
    /// @param amount Allowance amount.
    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        _call(address(token), abi.encodeCall(token.approve, (spender, amount)));
    }

    /// @notice Safely transfers tokens from the caller.
    /// @param token ERC-20 token to call.
    /// @param to Token recipient.
    /// @param amount Token amount to transfer.
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        _call(address(token), abi.encodeCall(token.transfer, (to, amount)));
    }

    /// @notice Safely transfers tokens with allowance.
    /// @param token ERC-20 token to call.
    /// @param from Token owner.
    /// @param to Token recipient.
    /// @param amount Token amount to transfer.
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        _call(address(token), abi.encodeCall(token.transferFrom, (from, to, amount)));
    }

    /// @notice Performs a low-level token call and validates optional boolean return data.
    /// @param token Token contract address.
    /// @param data ABI-encoded token call.
    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory result) = token.call(data);
        if (!ok || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert SafeERC20CallFailed();
        }
    }
}
