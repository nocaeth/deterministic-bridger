// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract MockAMB {
    address public messageSender;
    uint256 public messageSourceChainId;
    bytes32 public messageId;
    uint256 public maxGasPerTx = 2_000_000;
    uint256 public sourceChainId;
    uint256 public destinationChainId;
    bool public rejectSubmission;
    uint256 public submissions;
    uint256 public deliveries;
    bytes public lastData;
    address public lastTarget;

    constructor(uint256 source, uint256 destination) {
        sourceChainId = source;
        destinationChainId = destination;
    }

    function setRejectSubmission(bool value) external {
        rejectSubmission = value;
    }

    function requireToPassMessage(address target, bytes calldata data, uint256 gasLimit)
        external
        returns (bytes32)
    {
        require(!rejectSubmission && gasLimit <= maxGasPerTx, "AMB_SUBMISSION");
        lastData = data;
        lastTarget = target;
        return bytes32(++submissions);
    }

    function deliver(
        address target,
        address sender,
        uint256 chain,
        bytes calldata data,
        uint256 gasLimit
    ) external returns (bool success, bytes memory result) {
        messageSender = sender;
        messageSourceChainId = chain;
        messageId = bytes32(++deliveries);
        (success, result) = target.call{ gas: gasLimit }(data);
        messageSender = address(0);
        messageSourceChainId = 0;
        messageId = 0;
    }
}
