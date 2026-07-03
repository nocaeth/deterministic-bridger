// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ISavingsXDaiAdapter } from "../../src/interfaces/ISavingsXDaiAdapter.sol";

contract MockAdapter is ISavingsXDaiAdapter {
    error DepositFailed();

    bool public shouldRevert;
    address public lastReceiver;
    uint256 public lastValue;
    uint256 public lastShares;
    uint256 public totalValue;
    uint256 public callCount;
    mapping(address => uint256) public sharesOf;

    receive() external payable { }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function depositXDAI(address receiver) external payable returns (uint256 shares) {
        if (shouldRevert) revert DepositFailed();

        shares = msg.value;
        lastReceiver = receiver;
        lastValue = msg.value;
        lastShares = shares;
        totalValue += msg.value;
        sharesOf[receiver] += shares;
        callCount++;
    }
}
