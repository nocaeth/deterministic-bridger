// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { AmbVaultFixture } from "./AmbVaultFixture.sol";
import { SavingsXDaiSettlementVault as Vault } from "../src/SavingsXDaiSettlementVault.sol";
import { VaultClaimLib } from "../src/libraries/VaultClaimLib.sol";

contract SavingsXDaiSettlementVaultTest is AmbVaultFixture {
    function _pending(bytes32 id) private view {
        (, Vault.ClaimStatus status,) = vault.getClaim(id);
        assertEq(uint256(status), uint256(Vault.ClaimStatus.Pending));
    }

    function testOnlyAuthenticatedSourceMayRegister() external {
        bytes32 id = _bridgeUSDS(5 ether, 0);
        VaultClaimLib.Claim memory c = router.getClaim(id);
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
        VaultClaimLib.Claim memory c = router.getClaim(id);
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

    function testDuplicatePreservesLoweredMinimumAndConflictingOriginalRejected() external {
        bytes32 id = _bridgeUSDS(5 ether, 10 ether);
        _deliver(id);
        vm.prank(recipient);
        vault.lowerMinShares(id, 4 ether);
        assertTrue(_deliver(id));
        (VaultClaimLib.Claim memory original,, uint256 minimum) = vault.getClaim(id);
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
        home.setImplementation(address(1));
        vault.settle(pending);
        _pending(pending);
        home.setImplementation(address(home));
        vm.mockCallRevert(
            address(home), abi.encodeWithSelector(home.feeManagerContract.selector), ""
        );
        vault.settle(pending);
        _pending(pending);
        assertEq(adapter.callCount(), 1);
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
}
