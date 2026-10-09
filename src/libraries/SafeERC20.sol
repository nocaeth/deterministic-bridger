// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @notice ERC-20 calls that accept true or no return data from a contract.
library SafeERC20 {
    error SafeERC20CallFailed();

    /// @notice Safely approves a spender for a token amount.
    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        _call(address(token), abi.encodeCall(token.approve, (spender, amount)));
    }

    /// @notice Safely transfers tokens from the caller.
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        _call(address(token), abi.encodeCall(token.transfer, (to, amount)));
    }

    /// @notice Safely transfers tokens with allowance.
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        _call(address(token), abi.encodeCall(token.transferFrom, (from, to, amount)));
    }

    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory result) = token.call(data);
        if (!ok) revert SafeERC20CallFailed();
        if (result.length == 0) {
            if (token.code.length == 0) revert SafeERC20CallFailed();
        } else {
            uint256 returnValue;
            assembly ("memory-safe") {
                returnValue := mload(add(result, 32))
            }
            if (result.length < 32 || returnValue != 1) revert SafeERC20CallFailed();
        }
    }
}
