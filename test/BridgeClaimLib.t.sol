// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { BridgeClaimLib } from "../src/libraries/BridgeClaimLib.sol";

contract BridgeClaimLibTest is Test {
    function testCrossChainIdentityVector() external pure {
        assertEq(
            BridgeClaimLib.id(address(1), address(2), address(3), address(4), bytes32(uint256(5))),
            0x4900dda28136cfab089e6c61c4c8b57518c8c156b8323d87032a1d6aca63c8d4
        );
    }

    function testDeploymentAndNonceSeparateEntitlements() external pure {
        bytes32 original =
            BridgeClaimLib.id(address(1), address(2), address(3), address(4), bytes32(uint256(5)));
        assertNotEq(
            original,
            BridgeClaimLib.id(address(6), address(2), address(3), address(4), bytes32(uint256(5)))
        );
        assertNotEq(
            original,
            BridgeClaimLib.id(address(1), address(6), address(3), address(4), bytes32(uint256(5)))
        );
        assertNotEq(
            original,
            BridgeClaimLib.id(address(1), address(2), address(6), address(4), bytes32(uint256(5)))
        );
        assertNotEq(
            original,
            BridgeClaimLib.id(address(1), address(2), address(3), address(6), bytes32(uint256(5)))
        );
        assertNotEq(
            original,
            BridgeClaimLib.id(address(1), address(2), address(3), address(4), bytes32(uint256(6)))
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
        bytes32 original = BridgeClaimLib.id(router, foreignBridge, homeBridge, vault, nonce);
        address[4] memory domains = [router, foreignBridge, homeBridge, vault];
        uint256 field = uint256(fieldSeed) % 5;
        if (field == 4) nonce = bytes32(uint256(nonce) ^ 1);
        else domains[field] = address(uint160(domains[field]) ^ 1);
        assertNotEq(
            original, BridgeClaimLib.id(domains[0], domains[1], domains[2], domains[3], nonce)
        );
    }
}
