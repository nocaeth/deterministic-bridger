// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Adapter interface for depositing native xDAI into Savings xDAI.
interface ISavingsXDaiAdapter {
    /// @notice Deposits the attached native xDAI and credits sDAI shares to `receiver`.
    /// @return shares sDAI output in 18-decimal base units.
    function depositXDAI(address receiver) external payable returns (uint256 shares);
}
