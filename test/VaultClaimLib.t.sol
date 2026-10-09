// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { VaultClaimLib } from "../src/libraries/VaultClaimLib.sol";

contract VaultClaimLibTest is Test {
    function testCrossChainIdentityVector() external pure {
        assertEq(
            VaultClaimLib.id(address(1), address(2), address(3), address(4), bytes32(uint256(5))),
            0x3f8bfac765e93a77b906d116f3271bbb91edf0dce7cbd2d14896209b6bb903a3
        );
    }

    function testDeploymentAndNonceSeparateEntitlements() external pure {
        bytes32 original =
            VaultClaimLib.id(address(1), address(2), address(3), address(4), bytes32(uint256(5)));
        assertNotEq(
            original,
            VaultClaimLib.id(address(6), address(2), address(3), address(4), bytes32(uint256(5)))
        );
        assertNotEq(
            original,
            VaultClaimLib.id(address(1), address(6), address(3), address(4), bytes32(uint256(5)))
        );
        assertNotEq(
            original,
            VaultClaimLib.id(address(1), address(2), address(6), address(4), bytes32(uint256(5)))
        );
        assertNotEq(
            original,
            VaultClaimLib.id(address(1), address(2), address(3), address(6), bytes32(uint256(5)))
        );
        assertNotEq(
            original,
            VaultClaimLib.id(address(1), address(2), address(3), address(4), bytes32(uint256(6)))
        );
    }

    function testFuzzChangingAnyIdentityFieldSeparatesClaim(
        address router,
        address foreignBridge,
        address homeBridge,
        address vault,
        bytes32 nonce,
        uint8 fieldSeed
    ) external pure {
        bytes32 original = VaultClaimLib.id(router, foreignBridge, homeBridge, vault, nonce);
        address[4] memory domains = [router, foreignBridge, homeBridge, vault];
        uint256 field = uint256(fieldSeed) % 5;
        if (field == 4) nonce = bytes32(uint256(nonce) ^ 1);
        else domains[field] = address(uint160(domains[field]) ^ 1);
        assertNotEq(
            original, VaultClaimLib.id(domains[0], domains[1], domains[2], domains[3], nonce)
        );
    }
}
