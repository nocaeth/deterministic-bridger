// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { AmbVaultFixture } from "./AmbVaultFixture.sol";
import { SavingsXDaiSettlementVault as Vault } from "../src/SavingsXDaiSettlementVault.sol";
import { VaultClaimLib } from "../src/libraries/VaultClaimLib.sol";

contract AmbVaultHandler is AmbVaultFixture {
    struct Model {
        bytes32 bridgeNonce;
        address recipient;
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
    uint256 public bridgedAssets;
    mapping(address => uint256) public recipientShares;

    function create(uint256 amountSeed, uint256 minimumSeed, address recipientSeed, bool savings)
        external
    {
        if (ids.length >= 24) return;
        uint256 amount = bound(amountSeed, 1, 10 ether);
        uint256 minimum = bound(minimumSeed, 0, 20 ether);
        recipient = recipientSeed == address(0) ? address(1) : recipientSeed;
        bytes32 nonce = bytes32(foreign.nonce());
        bytes32 id = savings ? _bridgeSavings(amount, minimum) : _bridgeUSDS(amount, minimum);
        ids.push(id);
        model[id] = Model(nonce, recipient, amount, minimum, minimum, false, false, 0);
        bridgedAssets += amount;
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
        vm.prank(model[id].recipient);
        try vault.lowerMinShares(id, minimum) {
            model[id].minimum = minimum;
        } catch { }
    }

    function adapterBehavior(bool fail, uint256 ratioSeed) external {
        adapter.setBehavior(fail, false, bound(ratioSeed, 0, 3));
    }

    function unauthenticatedDelivery(uint256 seed, bool wrongSender) external {
        if (ids.length == 0) return;
        bytes32 id = ids[seed % ids.length];
        uint256 beforeCount = adapter.callCount();
        assertFalse(
            _deliverClaim(
                router.getClaim(id),
                wrongSender ? payer : address(router),
                wrongSender ? 1 : 100,
                700_000
            )
        );
        assertEq(adapter.callCount(), beforeCount);
    }

    function conflictingDelivery(uint256 seed, uint8 fieldSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[seed % ids.length];
        if (!model[id].registered) return;
        VaultClaimLib.Claim memory c = router.getClaim(id);
        uint256 field = uint256(fieldSeed) % 4;
        if (field == 0) c.payer = address(uint160(c.payer) ^ 1);
        else if (field == 1) c.recipient = address(uint160(c.recipient) ^ 1);
        else if (field == 2) c.amount++;
        else c.minShares++;
        uint256 beforeCount = adapter.callCount();
        assertFalse(_deliverClaim(c, address(router), 1, 700_000));
        assertEq(adapter.callCount(), beforeCount);
    }

    function unauthorizedMinimum(uint256 seed, uint256 minimumSeed, address attacker) external {
        if (ids.length == 0) return;
        bytes32 id = ids[seed % ids.length];
        if (attacker == model[id].recipient) attacker = address(uint160(attacker) ^ 1);
        vm.chainId(100);
        vm.prank(attacker);
        (bool success,) =
            address(vault).call(abi.encodeCall(vault.lowerMinShares, (id, minimumSeed)));
        assertFalse(success);
    }

    function unsupportedBridge(uint256 seed, uint8 modeSeed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[seed % ids.length];
        uint256 mode = uint256(modeSeed) % 6;
        vm.chainId(100);
        if (mode == 0) {
            home.setFeeManager(address(1));
        } else if (mode == 1) {
            home.setDecimalShift(1);
        } else if (mode == 2) {
            home.setImplementation(address(1));
        } else if (mode == 3) {
            vm.mockCallRevert(
                address(home), abi.encodeWithSelector(home.feeManagerContract.selector), ""
            );
        } else if (mode == 4) {
            vm.mockCallRevert(
                address(home), abi.encodeWithSelector(home.numAffirmationsSigned.selector), ""
            );
        } else {
            vm.mockCallRevert(
                address(home), abi.encodeWithSelector(home.isAlreadyProcessed.selector), ""
            );
        }
        uint256 beforeCount = adapter.callCount();
        vault.settle(id);
        assertEq(adapter.callCount(), beforeCount);
        home.setFeeManager(address(0));
        home.setDecimalShift(0);
        home.setImplementation(address(home));
        vm.clearMockedCalls();
    }

    function wrongChainSettlement(uint256 seed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[seed % ids.length];
        vm.chainId(1);
        uint256 beforeCount = adapter.callCount();
        vault.settle(id);
        assertEq(adapter.callCount(), beforeCount);
    }

    function _payment(bytes32 id, uint256 beforeCount) private {
        uint256 payments = adapter.callCount() - beforeCount;
        if (payments != 0) {
            assertEq(payments, 1);
            uint256 shares = model[id].amount * adapter.ratio();
            assertGt(shares, 0);
            assertGe(shares, model[id].minimum);
        }
        model[id].payments += payments;
        payouts += payments * model[id].amount;
        recipientShares[model[id].recipient] += payments * model[id].amount * adapter.ratio();
    }

    function checkModel() external view {
        assertEq(address(vault).balance, credits - payouts);
        assertEq(adapter.totalValue(), payouts);
        assertEq(usds.balanceOf(address(foreign)), bridgedAssets);
        assertEq(usds.balanceOf(address(router)), 0);
        assertEq(foreign.nonce(), ids.length);
        for (uint256 i; i < ids.length; i++) {
            bytes32 id = ids[i];
            Model memory expected = model[id];
            assertLe(expected.payments, 1);
            (VaultClaimLib.Claim memory original, Vault.ClaimStatus status, uint256 minimum) =
                vault.getClaim(id);
            if (expected.registered) {
                assertEq(original.payer, payer);
                assertEq(original.recipient, expected.recipient);
                assertEq(original.bridgeNonce, expected.bridgeNonce);
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
            assertEq(adapter.sharesOf(expected.recipient), recipientShares[expected.recipient]);
        }
    }
}

contract AmbVaultInvariantTest is StdInvariant, Test {
    AmbVaultHandler internal handler;

    function setUp() public {
        handler = new AmbVaultHandler();
        handler.setUp();
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.deliver.selector;
        selectors[2] = handler.execute.selector;
        selectors[3] = handler.credit.selector;
        selectors[4] = handler.settle.selector;
        selectors[5] = handler.resend.selector;
        selectors[6] = handler.lower.selector;
        selectors[7] = handler.adapterBehavior.selector;
        selectors[8] = handler.unauthenticatedDelivery.selector;
        selectors[9] = handler.conflictingDelivery.selector;
        selectors[10] = handler.unauthorizedMinimum.selector;
        selectors[11] = handler.unsupportedBridge.selector;
        selectors[12] = handler.wrongChainSettlement.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariantAuthenticatedAtMostOnceAndConservation() external view {
        handler.checkModel();
    }
}
