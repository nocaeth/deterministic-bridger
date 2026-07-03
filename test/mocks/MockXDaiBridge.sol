// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { IXDaiBridge } from "../../src/interfaces/IXDaiBridge.sol";

contract MockXDaiBridge is IXDaiBridge {
    IERC20 public immutable mainnetToken;
    address public lastCaller;
    address public lastReceiver;
    uint256 public lastAmount;
    uint256 public totalAmount;
    uint256 public callCount;

    constructor(IERC20 mainnetToken_) {
        mainnetToken = mainnetToken_;
    }

    function relayTokens(address receiver, uint256 amount) external {
        require(mainnetToken.transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM");

        lastCaller = msg.sender;
        lastReceiver = receiver;
        lastAmount = amount;
        totalAmount += amount;
        callCount++;
    }
}
