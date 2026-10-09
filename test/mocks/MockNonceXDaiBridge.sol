// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "../../src/interfaces/IERC20.sol";

contract MockNonceXDaiBridge {
    IERC20 public immutable token;
    address public implementation;
    uint256 public nonce;
    bool public rejectRelay;
    bool public pullShort;
    uint256 public nonceDelta = 1;
    address public lastReceiver;
    uint256 public lastAmount;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    bytes public reentryResult;

    event UserRequestForAffirmation(address recipient, uint256 value, bytes32 nonce);

    constructor(IERC20 token_) {
        token = token_;
        implementation = address(this);
    }

    function erc20token() external view returns (address) {
        return address(token);
    }

    function setRejectRelay(bool value) external {
        rejectRelay = value;
    }

    function setPullShort(bool value) external {
        pullShort = value;
    }

    function setNonceDelta(uint256 value) external {
        nonceDelta = value;
    }

    function setImplementation(address value) external {
        implementation = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function relayTokens(address receiver, uint256 amount) external {
        require(!rejectRelay, "LIMIT");
        if (reentryTarget != address(0)) {
            (reentrySucceeded, reentryResult) = reentryTarget.call(reentryData);
        }
        require(token.transferFrom(msg.sender, address(this), pullShort ? amount - 1 : amount));
        emit UserRequestForAffirmation(receiver, amount, bytes32(nonce));
        nonce += nonceDelta;
        lastReceiver = receiver;
        lastAmount = amount;
    }
}
