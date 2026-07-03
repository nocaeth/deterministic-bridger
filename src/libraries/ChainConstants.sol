// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ChainConstants
/// @notice Canonical addresses used by deployment scripts and fork smoke tests.
library ChainConstants {
    /// @notice Ethereum-side xDai bridge proxy used by default deployments.
    address internal constant ETHEREUM_XDAI_BRIDGE = 0x4aa42145Aa6Ebf72e164C9bBC74fbD3788045016;

    /// @notice Gnosis-side xDai bridge address checked by fork smoke tests.
    address internal constant GNOSIS_XDAI_BRIDGE = 0x7301CFA0e1756B71869E93d4e4Dca5c7d0eb0AA6;

    /// @notice Gnosis sDAI token address checked by fork smoke tests.
    address internal constant GNOSIS_SDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;
}
