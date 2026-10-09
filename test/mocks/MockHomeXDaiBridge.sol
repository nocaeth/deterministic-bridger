// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract MockHomeXDaiBridge {
    mapping(bytes32 => uint256) public numAffirmationsSigned;
    address public implementation;
    address public feeManagerContract;
    int256 public decimalShift;

    constructor() {
        implementation = address(this);
    }

    function setProcessed(bytes32 hash, bool value) external {
        numAffirmationsSigned[hash] = value ? 1 << 255 : 0;
    }

    function setCount(bytes32 hash, uint256 value) external {
        numAffirmationsSigned[hash] = value;
    }

    function isAlreadyProcessed(uint256 count) external pure returns (bool) {
        return count & (1 << 255) != 0;
    }

    function setImplementation(address value) external {
        implementation = value;
    }

    function setFeeManager(address value) external {
        feeManagerContract = value;
    }

    function setDecimalShift(int256 value) external {
        decimalShift = value;
    }
}
