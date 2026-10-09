// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { AmbRouterFixture } from "./AmbRouterFixture.sol";
import { GnosisAmbSettlementRouter as Vault } from "../src/GnosisAmbSettlementRouter.sol";
import { BridgeClaimLib } from "../src/libraries/BridgeClaimLib.sol";
import { IAMBClaimReceiver } from "../src/interfaces/IAMB.sol";

contract GnosisAmbSettlementRouterTest is AmbRouterFixture {
    event MinimumSharesLowered(bytes32 indexed claimId, uint256 newMinimum);

    function testMinimumChangeEventMatchesPublishedAbi() external {
        bytes32 id = _bridgeUSDS(5 ether, 10 ether);
        _deliver(id);
        vm.expectEmit(true, false, false, true, address(vault));
        emit MinimumSharesLowered(id, 4 ether);
        vm.prank(recipient);
        vault.lowerMinShares(id, 4 ether);
    }

    function testDistinctAmbDeliveryIdsCannotRepeatPayout() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        _execute(id);
        _credit(10 ether);
        _deliver(id);
        _deliver(id);
        _deliver(id);
        assertEq(adapter.callCount(), 1);
        assertEq(address(vault).balance, 5 ether);
    }

    function testSettlementRejectsReentryIntoOtherClaimAndMinimumMutation() external {
        bytes32 first = _bridgeUSDS(5 ether, 0);
        recipient = address(adapter);
        bytes32 second = _bridgeUSDS(6 ether, 0);
        bytes32 third = _bridgeUSDS(7 ether, 8 ether);
        _execute(first);
        _execute(second);
        _deliver(first);
        _deliver(second);
        _deliver(third);
        _credit(20 ether);
        adapter.setReentry(address(vault), abi.encodeCall(vault.settle, (second)));
        vault.settle(first);
        assertFalse(adapter.reentrySucceeded());
        _pending(second);
        adapter.setReentry(address(vault), abi.encodeCall(vault.lowerMinShares, (third, 0)));
        vault.settle(second);
        assertFalse(adapter.reentrySucceeded());
        (,, uint256 minimum) = vault.getClaim(third);
        assertEq(minimum, 8 ether);
        assertEq(adapter.callCount(), 2);
    }

    function testSettlementRejectsAuthenticatedRegistrationReentry() external {
        bytes32 first = _bridgeUSDS(5 ether, 0);
        bytes32 second = _bridgeUSDS(6 ether, 0);
        _execute(first);
        _execute(second);
        _deliver(first);
        _credit(20 ether);
        bytes memory registration =
            abi.encodeCall(IAMBClaimReceiver.registerClaim, (router.getClaim(second)));
        adapter.setReentry(
            address(amb),
            abi.encodeWithSelector(
                amb.deliver.selector,
                address(vault),
                address(router),
                uint256(1),
                registration,
                uint256(700_000)
            )
        );
        vault.settle(first);
        assertEq(uint256(vault.settlementStatus(second)), uint256(Vault.SettlementResult.Unknown));
        assertTrue(_deliver(second));
        assertEq(adapter.callCount(), 2);
    }

    function _pending(bytes32 id) private view {
        (, Vault.ClaimStatus status,) = vault.getClaim(id);
        assertEq(uint256(status), uint256(Vault.ClaimStatus.Pending));
    }

    function testOnlyAuthenticatedSourceMayRegister() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        BridgeClaimLib.Claim memory c = router.getClaim(id);
        vm.chainId(100);
        vm.expectRevert(Vault.UnauthorizedMessage.selector);
        vault.registerClaim(c);
        assertFalse(_deliverClaim(c, payer, 1, 700_000));
        assertFalse(_deliverClaim(c, address(router), 100, 700_000));
        _credit(100 ether);
        assertEq(uint256(vault.settlementStatus(id)), uint256(Vault.SettlementResult.Unknown));
        assertTrue(_deliver(id));
        _pending(id);
    }

    function testZeroClaimFieldsRejected() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        BridgeClaimLib.Claim memory c = router.getClaim(id);
        c.payer = address(0);
        assertFalse(_deliverClaim(c, address(router), 1, 700_000));
        c = router.getClaim(id);
        c.recipient = address(0);
        assertFalse(_deliverClaim(c, address(router), 1, 700_000));
        c = router.getClaim(id);
        c.amount = 0;
        assertFalse(_deliverClaim(c, address(router), 1, 700_000));
    }

    function testCashCannotReplaceCanonicalExecution() external {
        bytes32 id = _bridgeSavings(10 ether, 0);
        _credit(100 ether);
        assertTrue(_deliver(id));
        _pending(id);
        assertEq(adapter.callCount(), 0);
        assertEq(
            uint256(vault.settlementStatus(id)), uint256(Vault.SettlementResult.WaitingForBridge)
        );
        _execute(id);
        vault.settle(id);
        assertEq(adapter.lastReceiver(), recipient);
        assertEq(adapter.lastValue(), 10 ether);
        assertEq(address(vault).balance, 90 ether);
    }

    function testSignaturesAndWrongTransferHashesCannotAuthorizePayment() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        _credit(50 ether);
        _deliver(id);
        bytes32 nonce = router.getClaim(id).bridgeNonce;
        home.setCount(keccak256(abi.encodePacked(address(vault), uint256(5 ether), nonce)), 7);
        home.setProcessed(keccak256(abi.encodePacked(recipient, uint256(5 ether), nonce)), true);
        home.setProcessed(
            keccak256(abi.encodePacked(address(vault), uint256(6 ether), nonce)), true
        );
        home.setProcessed(
            keccak256(abi.encodePacked(address(vault), uint256(5 ether), bytes32(uint256(1)))), true
        );
        vault.settle(id);
        _pending(id);
        assertEq(adapter.callCount(), 0);
    }

    function testBothArrivalOrdersAndPermanentReplayProtection() external {
        bytes32 first = _bridgeUSDS(5 ether, 0);
        _execute(first);
        _credit(20 ether);
        _deliver(first);
        assertEq(adapter.callCount(), 1);
        bytes32 second = _bridgeSavings(6 ether, 0);
        _deliver(second);
        _execute(second);
        vault.settle(second);
        _deliver(first);
        _deliver(second);
        vault.settle(first);
        vault.settle(second);
        assertEq(adapter.callCount(), 2);
        assertEq(adapter.totalValue(), 11 ether);
    }

    function testInsufficientCashQueuesThenRetryPaysExactlyClaimAmount() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        _execute(id);
        _credit(2 ether);
        _deliver(id);
        assertEq(
            uint256(vault.settlementStatus(id)), uint256(Vault.SettlementResult.WaitingForLiquidity)
        );
        vault.settle(id);
        _pending(id);
        _credit(4 ether);
        vm.prank(payer);
        vault.settle(id);
        assertEq(adapter.lastValue(), 5 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function testExistingBridgeCreditCanSettleAnotherProcessedClaimWithoutSponsor() external {
        bytes32 first = _bridgeUSDS(5 ether, 0);
        bytes32 second = _bridgeUSDS(6 ether, 0);
        _execute(first);
        _execute(second);
        _credit(6 ether); // Only the second transfer has credited native xDAI so far.
        _deliver(first);
        assertEq(adapter.totalValue(), 5 ether);
        _deliver(second);
        _pending(second);
        assertEq(
            uint256(vault.settlementStatus(second)),
            uint256(Vault.SettlementResult.WaitingForLiquidity)
        );
        _credit(5 ether);
        vault.settle(second);
        assertEq(adapter.totalValue(), 11 ether);
        assertEq(address(vault).balance, 0);
    }

    function testDuplicatePreservesLoweredMinimumAndConflictingOriginalRejected() external {
        bytes32 id = _bridgeUSDS(5 ether, 10 ether);
        _deliver(id);
        vm.prank(recipient);
        vault.lowerMinShares(id, 4 ether);
        assertTrue(_deliver(id));
        (BridgeClaimLib.Claim memory original,, uint256 minimum) = vault.getClaim(id);
        assertEq(original.minShares, 10 ether);
        assertEq(minimum, 4 ether);
        original.recipient = payer;
        assertFalse(_deliverClaim(original, address(router), 1, 700_000));
        original = router.getClaim(id);
        original.amount++;
        assertFalse(_deliverClaim(original, address(router), 1, 700_000));
        _execute(id);
        _credit(5 ether);
        vault.settle(id);
        _deliver(id);
        assertEq(adapter.callCount(), 1);
    }

    function testOnlyRecipientCanLowerPendingMinimum() external {
        bytes32 id = _bridgeUSDS(5 ether, 10 ether);
        _deliver(id);
        vm.expectRevert(Vault.InvalidMinimum.selector);
        vault.lowerMinShares(id, 1);
        vm.expectRevert(Vault.InvalidMinimum.selector);
        vm.prank(recipient);
        vault.lowerMinShares(id, 11 ether);
        vm.prank(recipient);
        vault.lowerMinShares(id, 0);
        _execute(id);
        _credit(5 ether);
        vault.settle(id);
        vm.expectRevert(Vault.InvalidMinimum.selector);
        vm.prank(recipient);
        vault.lowerMinShares(id, 0);
    }

    function testAdapterFailureKeepsRegistrationAndCashForRetry() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        _execute(id);
        _credit(5 ether);
        adapter.setBehavior(true, false, 1);
        assertTrue(_deliver(id));
        _pending(id);
        assertEq(address(vault).balance, 5 ether);
        assertEq(adapter.callCount(), 0);
        vm.expectRevert();
        vault.settle(id);
        _pending(id);
        adapter.setBehavior(false, false, 1);
        vault.settle(id);
        assertEq(adapter.callCount(), 1);
    }

    function testMinimumAndZeroSharesCannotConsumeCash() external {
        bytes32 id = _bridgeUSDS(5 ether, 6 ether);
        _execute(id);
        _credit(5 ether);
        _deliver(id);
        _pending(id);
        vm.prank(recipient);
        vault.lowerMinShares(id, 0);
        adapter.setBehavior(false, false, 0);
        vm.expectRevert(Vault.InsufficientShares.selector);
        vault.settle(id);
        _pending(id);
        assertEq(address(vault).balance, 5 ether);
        adapter.setBehavior(false, false, 1);
        vault.settle(id);
        assertEq(adapter.totalValue(), 5 ether);
    }

    function testExhaustedChildCannotEraseRegistration() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        _execute(id);
        _credit(5 ether);
        adapter.setBehavior(false, true, 1);
        assertTrue(_deliver(id));
        _pending(id);
        assertEq(address(vault).balance, 5 ether);
        adapter.setBehavior(false, false, 1);
        vault.settle(id);
        assertEq(adapter.callCount(), 1);
    }

    function testRegistrationOutOfGasRecoversThroughSourceResend() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        assertFalse(_deliverClaim(router.getClaim(id), address(router), 1, 20_000));
        assertEq(uint256(vault.settlementStatus(id)), uint256(Vault.SettlementResult.Unknown));
        vm.chainId(1);
        router.resendClaim(id);
        assertTrue(_deliver(id));
        _pending(id);
        assertEq(foreign.nonce(), 1);
    }

    function testSettlementReentryCannotDoublePayOrMutateClaim() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        _execute(id);
        _credit(20 ether);
        adapter.setReentry(address(vault), abi.encodeCall(vault.settle, (id)));
        _deliver(id);
        assertFalse(adapter.reentrySucceeded());
        assertEq(adapter.callCount(), 1);
        assertEq(address(vault).balance, 15 ether);
    }

    function testUnsupportedConfigurationPausesSettlement() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        _execute(id);
        _credit(5 ether);
        _deliver(id);
        bytes32 pending = _bridgeUSDS(6 ether, 0);
        _execute(pending);
        _deliver(pending);
        _credit(6 ether);
        home.setFeeManager(address(1));
        assertEq(
            uint256(vault.settlementStatus(pending)),
            uint256(Vault.SettlementResult.UnsupportedBridgeConfig)
        );
        vault.settle(pending);
        _pending(pending);
        home.setFeeManager(address(0));
        home.setDecimalShift(1);
        vault.settle(pending);
        _pending(pending);
        home.setDecimalShift(0);
        vm.mockCallRevert(
            address(home), abi.encodeWithSelector(home.feeManagerContract.selector), ""
        );
        vault.settle(pending);
        _pending(pending);
        vm.clearMockedCalls();
        home.setImplementation(address(1));
        vault.settle(pending);
        assertEq(uint256(vault.settlementStatus(pending)), uint256(Vault.SettlementResult.Paid));
        assertEq(adapter.callCount(), 2);
    }

    function testRevertingBridgeGettersPauseSettlement() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        _execute(id);
        _deliver(id);
        _credit(5 ether);
        bytes4[2] memory selectors = [home.feeManagerContract.selector, home.decimalShift.selector];
        for (uint256 i; i < selectors.length; ++i) {
            vm.mockCallRevert(address(home), abi.encodeWithSelector(selectors[i]), "");
            assertEq(
                uint256(vault.settlementStatus(id)),
                uint256(Vault.SettlementResult.UnsupportedBridgeConfig)
            );
            vault.settle(id);
            _pending(id);
            vm.clearMockedCalls();
        }
        assertEq(adapter.callCount(), 0);
    }

    function testUnknownAndPaidSettlementAreNoOps() external {
        vm.chainId(100);
        vault.settle(bytes32(uint256(99)));
        bytes32 id = _bridgeUSDS(5 ether, 0);
        _execute(id);
        _credit(5 ether);
        _deliver(id);
        vault.settle(id);
        assertEq(adapter.callCount(), 1);
    }

    function testFuzzUnauthenticatedMessagesCannotReleaseReadyFunds(
        address attacker,
        uint256 sourceChain,
        uint128 amountSeed
    ) external {
        uint256 amount = bound(amountSeed, 1, 1e30);
        bytes32 id = _bridgeUSDS(amount, 0);
        BridgeClaimLib.Claim memory claim = router.getClaim(id);
        _execute(id);
        _credit(amount);
        if (attacker == address(amb)) attacker = address(1);
        vm.prank(attacker);
        (bool directSuccess,) =
            address(vault).call(abi.encodeCall(IAMBClaimReceiver.registerClaim, (claim)));
        assertFalse(directSuccess);
        address wrongSender = attacker == address(router) ? address(1) : attacker;
        assertFalse(_deliverClaim(claim, wrongSender, 1, 700_000));
        if (sourceChain == 1) sourceChain = 100;
        assertFalse(_deliverClaim(claim, address(router), sourceChain, 700_000));
        assertEq(uint256(vault.settlementStatus(id)), uint256(Vault.SettlementResult.Unknown));
        assertEq(adapter.callCount(), 0);
        assertEq(address(vault).balance, amount);
    }

    function testFuzzRecipientControlsOnlyDownwardPendingMinimum(
        address receiver,
        address attacker,
        uint128 minimumSeed,
        uint256 newMinimumSeed
    ) external {
        recipient = receiver == address(0) ? address(1) : receiver;
        if (attacker == recipient) attacker = address(uint160(attacker) ^ 1);
        uint256 originalMinimum = bound(minimumSeed, 1, 1e30);
        uint256 newMinimum = bound(newMinimumSeed, 0, originalMinimum);
        bytes32 id = _bridgeUSDS(5 ether, originalMinimum);
        assertTrue(_deliver(id));
        vm.expectRevert(Vault.InvalidMinimum.selector);
        vm.prank(attacker);
        vault.lowerMinShares(id, newMinimum);
        vm.expectRevert(Vault.InvalidMinimum.selector);
        vm.prank(recipient);
        vault.lowerMinShares(id, originalMinimum + 1);
        vm.prank(recipient);
        vault.lowerMinShares(id, newMinimum);
        assertTrue(_deliver(id));
        (BridgeClaimLib.Claim memory original, Vault.ClaimStatus status, uint256 effectiveMinimum) =
            vault.getClaim(id);
        assertEq(original.recipient, recipient);
        assertEq(original.minShares, originalMinimum);
        assertEq(effectiveMinimum, newMinimum);
        assertEq(uint256(status), uint256(Vault.ClaimStatus.Pending));
        assertEq(adapter.callCount(), 0);
    }

    function testFuzzFailedConversionRollsBackThenPaysOnce(
        uint128 amountSeed,
        uint128 bufferSeed,
        uint8 rateSeed,
        uint256 acceptedMinimumSeed,
        address receiver
    ) external {
        uint256 amount = bound(amountSeed, 1, 1e24);
        uint256 buffer = bound(bufferSeed, 0, 1e30);
        uint256 rate = bound(rateSeed, 1, 10);
        uint256 expectedShares = amount * rate;
        recipient = receiver == address(0) ? address(1) : receiver;
        bytes32 id = _bridgeUSDS(amount, expectedShares + 1);
        adapter.setBehavior(false, false, rate);
        _execute(id);
        _credit(amount + buffer);
        assertTrue(_deliver(id));
        vm.expectRevert(Vault.InsufficientShares.selector);
        vault.settle(id);
        _pending(id);
        assertEq(address(vault).balance, amount + buffer);
        assertEq(adapter.totalValue(), 0);
        assertEq(adapter.sharesOf(recipient), 0);
        uint256 acceptedMinimum = bound(acceptedMinimumSeed, 0, expectedShares);
        vm.prank(recipient);
        vault.lowerMinShares(id, acceptedMinimum);
        vm.prank(address(0xCAFE));
        (Vault.SettlementResult result, uint256 shares) = vault.settle(id);
        assertEq(uint256(result), uint256(Vault.SettlementResult.Paid));
        assertEq(shares, expectedShares);
        assertEq(adapter.sharesOf(recipient), expectedShares);
        assertEq(adapter.totalValue(), amount);
        assertEq(address(vault).balance, buffer);
        assertTrue(_deliver(id));
        vault.settle(id);
        assertEq(adapter.callCount(), 1);
        vm.expectRevert(Vault.InvalidMinimum.selector);
        vm.prank(recipient);
        vault.lowerMinShares(id, 0);
    }

    function testFuzzWrongTransferCommitmentsCannotUseBuffer(
        uint128 amountSeed,
        bytes32 wrongNonce,
        address wrongReceiver
    ) external {
        uint256 amount = bound(amountSeed, 1, 1e30);
        bytes32 id = _bridgeUSDS(amount, 0);
        BridgeClaimLib.Claim memory claim = router.getClaim(id);
        if (wrongNonce == claim.bridgeNonce) wrongNonce = bytes32(uint256(wrongNonce) ^ 1);
        if (wrongReceiver == address(vault)) wrongReceiver = address(1);
        _credit(amount);
        assertTrue(_deliver(id));
        home.setProcessed(
            keccak256(abi.encodePacked(wrongReceiver, amount, claim.bridgeNonce)), true
        );
        home.setProcessed(
            keccak256(abi.encodePacked(address(vault), amount + 1, claim.bridgeNonce)), true
        );
        home.setProcessed(keccak256(abi.encodePacked(address(vault), amount, wrongNonce)), true);
        vault.settle(id);
        _pending(id);
        assertEq(adapter.callCount(), 0);
        assertEq(address(vault).balance, amount);
        assertEq(
            uint256(vault.settlementStatus(id)), uint256(Vault.SettlementResult.WaitingForBridge)
        );
    }
}
