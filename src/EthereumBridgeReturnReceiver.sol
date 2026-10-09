// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "./interfaces/IERC20.sol";
import { ChainConstants } from "./libraries/ChainConstants.sol";
import { SafeERC20 } from "./libraries/SafeERC20.sol";

/// @notice Manual custody for canonical bridge returns to the Gnosis settlement router's Ethereum address.
contract EthereumBridgeReturnReceiver {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InvalidRecovery();

    address public immutable recoveryAuthority;

    event Recovered(address indexed token, address indexed recipient, uint256 amount);

    constructor(address authority) {
        if (block.chainid != ChainConstants.ETHEREUM_CHAIN_ID || authority == address(0)) {
            revert InvalidRecovery();
        }
        recoveryAuthority = authority;
    }

    function recover(address token, address recipient, uint256 amount) external {
        if (msg.sender != recoveryAuthority) revert Unauthorized();
        if (
            (token != ChainConstants.ETHEREUM_USDS && token != ChainConstants.ETHEREUM_DAI)
                || recipient == address(0) || amount == 0
        ) revert InvalidRecovery();
        IERC20(token).safeTransfer(recipient, amount);
        emit Recovered(token, recipient, amount);
    }
}
