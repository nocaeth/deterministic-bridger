// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ChainConstants } from "./ChainConstants.sol";

/// @notice Immutable claim payload and bridge-lane-specific claim identity.
library BridgeClaimLib {
    bytes32 private constant PROTOCOL_DOMAIN = keccak256("SDAI_AMB_ROUTER_V1");

    struct Claim {
        /// @notice Canonical foreign bridge nonce consumed by this transfer.
        bytes32 bridgeNonce;
        /// @notice Ethereum caller whose USDS or sUSDS funded the transfer.
        address payer;
        /// @notice Gnosis account entitled to the resulting sDAI shares.
        address recipient;
        /// @notice USDS bridged, and xDAI to settle, in 18-decimal base units.
        uint256 amount;
        /// @notice Original minimum sDAI shares, in 18-decimal base units.
        uint256 minShares;
    }

    /// @notice Derives the same claim identity on Ethereum and Gnosis.
    function id(
        address router,
        address foreignBridge,
        address homeBridge,
        address gnosisRouter,
        bytes32 bridgeNonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PROTOCOL_DOMAIN,
                ChainConstants.ETHEREUM_CHAIN_ID,
                ChainConstants.GNOSIS_CHAIN_ID,
                router,
                foreignBridge,
                homeBridge,
                gnosisRouter,
                bridgeNonce
            )
        );
    }
}
