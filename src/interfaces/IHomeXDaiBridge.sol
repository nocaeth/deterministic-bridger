// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IHomeXDaiBridge {
    function numAffirmationsSigned(bytes32 transferHash) external view returns (uint256);
    function isAlreadyProcessed(uint256 count) external pure returns (bool);
    function implementation() external view returns (address);
    function feeManagerContract() external view returns (address);
    function decimalShift() external view returns (int256);
}
