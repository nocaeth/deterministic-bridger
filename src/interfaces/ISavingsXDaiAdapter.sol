// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ISavingsXDaiAdapter
/// @notice Adapter interface for depositing native xDAI into Savings xDAI.
interface ISavingsXDaiAdapter {
    /// @notice Deposits the attached native xDAI and credits sDAI shares to `receiver`.
    /// @param receiver Deterministic receiver that should receive or be credited with sDAI shares.
    /// @return shares sDAI shares minted or transferred by the adapter.
    function depositXDAI(address receiver) external payable returns (uint256 shares);
}
