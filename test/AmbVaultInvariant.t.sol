// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { AmbVaultFixture } from "./AmbVaultFixture.sol";
import { SavingsXDaiSettlementVault as Vault } from "../src/SavingsXDaiSettlementVault.sol";
import { VaultClaimLib } from "../src/libraries/VaultClaimLib.sol";

contract AmbVaultHandler is AmbVaultFixture {
    struct Model {
        uint256 amount;
        uint256 originalMinimum;
        uint256 minimum;
        bool registered;
        bool executed;
        uint256 payments;
    }
    bytes32[] public ids;
    mapping(bytes32 => Model) public model;
    uint256 public credits;
    uint256 public payouts;

    function create(uint256 amountSeed, uint256 minimumSeed, bool savings) external {
        if (ids.length >= 24) return;
        uint256 amount = bound(amountSeed, 1, 10 ether);
        uint256 minimum = bound(minimumSeed, 0, 20 ether);
        bytes32 id = savings ? _bridgeSavings(amount, minimum) : _bridgeUSDS(amount, minimum);
        ids.push(id);
        model[id] = Model(amount, minimum, minimum, false, false, 0);
    }

    function deliver(uint256 seed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[seed % ids.length];
        uint256 beforeCount = adapter.callCount();
        bool success = _deliver(id);
        if (success) model[id].registered = true;
        _payment(id, beforeCount);
    }

    function execute(uint256 seed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[seed % ids.length];
        _execute(id);
        model[id].executed = true;
    }

    function credit(uint256 seed) external {
        uint256 amount = bound(seed, 0, 10 ether);
        _credit(amount);
        credits += amount;
    }

    function settle(uint256 seed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[seed % ids.length];
        vm.chainId(100);
        uint256 beforeCount = adapter.callCount();
        try vault.settle(id) { } catch { }
        _payment(id, beforeCount);
    }

    function resend(uint256 seed) external {
        if (ids.length == 0) return;
        vm.chainId(1);
        router.resendClaim(ids[seed % ids.length]);
    }

    function lower(uint256 seed, uint256 minimumSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[seed % ids.length];
        uint256 minimum = bound(minimumSeed, 0, model[id].minimum);
        vm.chainId(100);
        vm.prank(recipient);
        try vault.lowerMinShares(id, minimum) {
            model[id].minimum = minimum;
        }
            catch { }
    }

    function adapterFailure(bool fail) external {
        adapter.setBehavior(fail, false, 1);
    }

    function _payment(bytes32 id, uint256 beforeCount) private {
        uint256 payments = adapter.callCount() - beforeCount;
        model[id].payments += payments;
        payouts += payments * model[id].amount;
    }

    function checkModel() external view {
        assertEq(address(vault).balance, credits - payouts);
        assertEq(adapter.totalValue(), payouts);
        for (uint256 i; i < ids.length; i++) {
            bytes32 id = ids[i];
            Model memory expected = model[id];
            assertLe(expected.payments, 1);
            (VaultClaimLib.Claim memory original, Vault.ClaimStatus status, uint256 minimum) =
                vault.getClaim(id);
            if (expected.registered) {
                assertEq(original.payer, payer);
                assertEq(original.recipient, recipient);
                assertEq(original.amount, expected.amount);
                assertEq(original.minShares, expected.originalMinimum);
                assertEq(minimum, expected.minimum);
                assertEq(
                    uint256(status),
                    uint256(
                        expected.payments == 1 ? Vault.ClaimStatus.Paid : Vault.ClaimStatus.Pending
                    )
                );
            } else {
                assertEq(uint256(status), uint256(Vault.ClaimStatus.Unknown));
            }
            if (expected.payments != 0) {
                assertTrue(expected.registered);
                assertTrue(expected.executed);
            }
        }
    }
}

contract AmbVaultInvariantTest is StdInvariant, Test {
    AmbVaultHandler internal handler;

    function setUp() public {
        handler = new AmbVaultHandler();
        handler.setUp();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.deliver.selector;
        selectors[2] = handler.execute.selector;
        selectors[3] = handler.credit.selector;
        selectors[4] = handler.settle.selector;
        selectors[5] = handler.resend.selector;
        selectors[6] = handler.lower.selector;
        selectors[7] = handler.adapterFailure.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariantAuthenticatedAtMostOnceAndConservation() external view {
        handler.checkModel();
    }
}
