// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Canonical Gnosis bridge execution marker and compatibility getters.
interface IHomeXDaiBridge {
    /// @notice Returns the affirmation count, including its processed flag, for an exact transfer.
    function numAffirmationsSigned(bytes32 transferHash) external view returns (uint256);
    /// @notice Checks the processed flag in an affirmation count.
    function isAlreadyProcessed(uint256 count) external pure returns (bool);
    /// @notice Returns the bridge proxy's current implementation.
    function implementation() external view returns (address);
    /// @notice Returns the configured fee manager, or zero when absent.
    function feeManagerContract() external view returns (address);
    /// @notice Returns the configured amount decimal shift.
    function decimalShift() external view returns (int256);
}
