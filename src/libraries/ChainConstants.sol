// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ChainConstants
/// @notice Canonical addresses used by the vault protocol, deployment scripts and fork tests.
library ChainConstants {
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint256 internal constant GNOSIS_CHAIN_ID = 100;

    /// @notice Ethereum USDS token currently accepted by the canonical xDai bridge.
    address internal constant ETHEREUM_USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    /// @notice DAI is an alternate token for a canonical above-limit bridge return.
    address internal constant ETHEREUM_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /// @notice Ethereum sUSDS ERC-4626 vault accepted by the router as an input token.
    address internal constant ETHEREUM_SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    /// @notice Ethereum-side xDai bridge proxy used by default deployments.
    address internal constant ETHEREUM_XDAI_BRIDGE = 0x4aa42145Aa6Ebf72e164C9bBC74fbD3788045016;

    /// @notice Gnosis-side xDai bridge address checked by pinned integration tests.
    address internal constant GNOSIS_XDAI_BRIDGE = 0x7301CFA0e1756B71869E93d4e4Dca5c7d0eb0AA6;

    /// @notice Gnosis sDAI token address checked by pinned integration tests.
    address internal constant GNOSIS_SDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;
}
