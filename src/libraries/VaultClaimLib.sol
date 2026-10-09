// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

library VaultClaimLib {
    struct Claim {
        bytes32 bridgeNonce;
        address payer;
        address recipient;
        uint256 amount;
        uint256 minShares;
    }

    function id(
        address router,
        address foreignBridge,
        address homeBridge,
        address vault,
        bytes32 bridgeNonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("SDAI_AMB_VAULT_V1"),
                uint256(1),
                uint256(100),
                router,
                foreignBridge,
                homeBridge,
                vault,
                bridgeNonce
            )
        );
    }
}
