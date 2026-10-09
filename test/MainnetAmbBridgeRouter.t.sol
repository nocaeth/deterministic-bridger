// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { MainnetAmbBridgeRouter } from "../src/MainnetAmbBridgeRouter.sol";
import { IAMB } from "../src/interfaces/IAMB.sol";
import { INonceXDaiBridge } from "../src/interfaces/INonceXDaiBridge.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { VaultClaimLib } from "../src/libraries/VaultClaimLib.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC4626 } from "./mocks/MockERC4626.sol";
import { MockNonceXDaiBridge } from "./mocks/MockNonceXDaiBridge.sol";
import { MockAMB } from "./mocks/MockAMB.sol";
import { ReentrancyGuard } from "../src/utils/ReentrancyGuard.sol";

contract MainnetAmbBridgeRouterTest is Test {
    MainnetAmbBridgeRouter internal router;
    MockERC20 internal usds;
    MockERC4626 internal susds;
    MockNonceXDaiBridge internal foreign;
    MockAMB internal amb;
    address internal payer = address(0xB0B);
    address internal recipient = address(0xA11CE);
    address internal vault = address(0x1234);

    function setUp() public {
        vm.chainId(1);
        vm.etch(ChainConstants.ETHEREUM_USDS, address(new MockERC20()).code);
        usds = MockERC20(ChainConstants.ETHEREUM_USDS);
        vm.etch(ChainConstants.ETHEREUM_SUSDS, address(new MockERC4626(usds)).code);
        susds = MockERC4626(ChainConstants.ETHEREUM_SUSDS);
        susds.setAssetsPerShare(1);
        foreign = new MockNonceXDaiBridge(IERC20(address(usds)));
        amb = new MockAMB(1, 100);
        router = new MainnetAmbBridgeRouter(
            INonceXDaiBridge(address(foreign)), IAMB(address(amb)), address(0x5678), vault
        );
    }

    function _fundSavings(uint256 shares) internal {
        susds.mint(payer, shares);
        vm.prank(payer);
        susds.approve(address(router), shares);
    }

    function testSavingsClaimExcludesOldRouterBalance() external {
        usds.mint(address(router), 50 ether);
        susds.setAssetsPerShare(2);
        _fundSavings(4 ether);
        vm.prank(payer);
        (bytes32 id, uint256 amount) = router.bridgeSavingsUSDSTo(recipient, 4 ether, 3 ether);
        VaultClaimLib.Claim memory c = router.getClaim(id);
        assertEq(c.payer, payer);
        assertEq(c.recipient, recipient);
        assertEq(c.amount, 8 ether);
        assertEq(c.minShares, 3 ether);
        assertEq(c.bridgeNonce, bytes32(0));
        assertEq(amount, 8 ether);
        assertEq(susds.balanceOf(payer), 0);
        assertEq(usds.balanceOf(address(router)), 50 ether);
        assertEq(usds.balanceOf(address(foreign)), 8 ether);
        assertEq(foreign.lastReceiver(), vault);
        assertEq(usds.allowance(address(router), address(foreign)), 0);
    }

    function testBothCallerDefaultVariantsBindPayer() external {
        _fundSavings(2 ether);
        vm.prank(payer);
        (bytes32 savingsId,) = router.bridgeSavingsUSDS(2 ether, 0);
        assertEq(router.getClaim(savingsId).recipient, payer);
        usds.mint(payer, 3 ether);
        vm.prank(payer);
        usds.approve(address(router), 3 ether);
        vm.prank(payer);
        (bytes32 usdsId,) = router.bridge(3 ether, 0);
        assertEq(router.getClaim(usdsId).recipient, payer);
        assertNotEq(savingsId, usdsId);
    }

    function testUsdsToUsesCallerFundsAndSpecifiedRecipient() external {
        usds.mint(payer, 3 ether);
        vm.prank(payer);
        usds.approve(address(router), 3 ether);
        vm.prank(payer);
        (bytes32 id,) = router.bridgeTo(recipient, 3 ether, 0);
        assertEq(router.getClaim(id).recipient, recipient);
        assertEq(usds.balanceOf(payer), 0);
        assertEq(usds.balanceOf(address(foreign)), 3 ether);
    }

    function testSourceLimitRollsBackRedemptionAndClaim() external {
        foreign.setRejectRelay(true);
        _expectSavingsRollback();
    }

    function testAmbFailureRollsBackBridgeAndClaim() external {
        amb.setRejectSubmission(true);
        _expectSavingsRollback();
    }

    function testZeroAmbMessageIdRollsBackBridgeAndClaim() external {
        vm.mockCall(
            address(amb),
            abi.encodeWithSelector(amb.requireToPassMessage.selector),
            abi.encode(bytes32(0))
        );
        _expectSavingsRollback();
    }

    function testWrongNonceRollsBackBridgeAndClaim() external {
        foreign.setNonceDelta(2);
        _expectSavingsRollback();
    }

    function testShortPullRollsBackBridgeAndClaim() external {
        foreign.setPullShort(true);
        _expectSavingsRollback();
    }

    function _expectSavingsRollback() internal {
        _fundSavings(5 ether);
        usds.mint(address(router), 7 ether);
        bytes32 expected =
            VaultClaimLib.id(address(router), address(foreign), address(0x5678), vault, bytes32(0));
        vm.expectRevert();
        vm.prank(payer);
        router.bridgeSavingsUSDSTo(recipient, 5 ether, 0);
        assertEq(susds.balanceOf(payer), 5 ether);
        assertEq(susds.allowance(payer, address(router)), 5 ether);
        assertEq(usds.balanceOf(address(router)), 7 ether);
        assertEq(usds.balanceOf(address(foreign)), 0);
        assertEq(foreign.nonce(), 0);
        assertEq(amb.submissions(), 0);
        assertEq(router.getClaim(expected).payer, address(0));
        assertEq(usds.allowance(address(router), address(foreign)), 0);
    }

    function testResendIsSameEntitlementWithoutNewBridge() external {
        _fundSavings(5 ether);
        vm.prank(payer);
        (bytes32 id,) = router.bridgeSavingsUSDSTo(recipient, 5 ether, 0);
        bytes memory original = amb.lastData();
        vm.prank(address(0xCAFE));
        bytes32 message = router.resendClaim(id);
        assertEq(amb.lastData(), original);
        assertEq(message, bytes32(uint256(2)));
        assertEq(foreign.nonce(), 1);
        assertEq(usds.balanceOf(address(foreign)), 5 ether);
        assertEq(susds.balanceOf(payer), 0);
    }

    function testUnknownResendRejected() external {
        vm.expectRevert(MainnetAmbBridgeRouter.UnknownClaim.selector);
        router.resendClaim(bytes32(uint256(99)));
    }

    function testRedemptionFailureNeverRelaysOrSendsClaim() external {
        _fundSavings(5 ether);
        vm.prank(payer);
        susds.approve(address(router), 1 ether);
        vm.expectRevert();
        vm.prank(payer);
        router.bridgeSavingsUSDS(5 ether, 0);
        assertEq(susds.balanceOf(payer), 5 ether);
        assertEq(susds.allowance(payer, address(router)), 1 ether);
        assertEq(foreign.nonce(), 0);
        assertEq(amb.submissions(), 0);
    }

    function testReportedUsdsTransferWithoutFundingCannotUseExistingRouterCash() external {
        usds.mint(address(router), 10 ether);
        vm.mockCall(
            address(usds), abi.encodeWithSelector(usds.transferFrom.selector), abi.encode(true)
        );
        vm.expectRevert(MainnetAmbBridgeRouter.FundingMismatch.selector);
        vm.prank(payer);
        router.bridge(5 ether, 0);
        assertEq(usds.balanceOf(address(router)), 10 ether);
        assertEq(foreign.nonce(), 0);
        assertEq(amb.submissions(), 0);
    }

    function testWrongRedemptionReturnCannotUseExistingBalance() external {
        _fundSavings(5 ether);
        usds.mint(address(router), 10 ether);
        vm.mockCall(
            address(susds), abi.encodeWithSelector(susds.redeem.selector), abi.encode(5 ether)
        );
        vm.expectRevert(MainnetAmbBridgeRouter.FundingMismatch.selector);
        vm.prank(payer);
        router.bridgeSavingsUSDS(5 ether, 0);
        assertEq(usds.balanceOf(address(router)), 10 ether);
        assertEq(amb.submissions(), 0);
    }

    function testInvalidInputsNeverSendMessage() external {
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidReceiver.selector);
        router.bridgeTo(address(0), 1, 0);
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidAmount.selector);
        router.bridge(0, 0);
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidAmount.selector);
        router.bridgeSavingsUSDS(0, 0);
        assertEq(amb.submissions(), 0);
    }

    function testImplementationChangeCannotCreateNewClaim() external {
        foreign.setImplementation(address(0xFADE));
        vm.expectRevert(MainnetAmbBridgeRouter.UnsupportedBridge.selector);
        router.bridge(1, 0);
    }

    function testBridgeCallbackCannotResendExistingClaim() external {
        _fundSavings(2 ether);
        vm.prank(payer);
        (bytes32 first,) = router.bridgeSavingsUSDS(2 ether, 0);
        foreign.setReentry(address(router), abi.encodeCall(router.resendClaim, (first)));
        _fundSavings(3 ether);
        vm.prank(payer);
        (bytes32 second,) = router.bridgeSavingsUSDS(3 ether, 0);
        assertFalse(foreign.reentrySucceeded());
        assertEq(
            foreign.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrantCall.selector)
        );
        assertNotEq(first, second);
        assertEq(foreign.nonce(), 2);
        assertEq(amb.submissions(), 2);
        assertEq(usds.balanceOf(address(foreign)), 5 ether);
    }

    function testBridgeCallbackCannotEnterAnotherFundingMethod() external {
        foreign.setReentry(address(router), abi.encodeCall(router.bridge, (0, 0)));
        _fundSavings(3 ether);
        vm.prank(payer);
        router.bridgeSavingsUSDS(3 ether, 0);
        assertFalse(foreign.reentrySucceeded());
        assertEq(
            foreign.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrantCall.selector)
        );
        assertEq(foreign.nonce(), 1);
        assertEq(amb.submissions(), 1);
    }

    function testAmbCallbackCannotResendClaimBeingSubmitted() external {
        bytes32 expectedId = VaultClaimLib.id(
            address(router), address(foreign), address(0x5678), vault, bytes32(0)
        );
        amb.setReentry(address(router), abi.encodeCall(router.resendClaim, (expectedId)));
        _fundSavings(3 ether);
        vm.prank(payer);
        (bytes32 id,) = router.bridgeSavingsUSDS(3 ether, 0);
        assertEq(id, expectedId);
        assertFalse(amb.reentrySucceeded());
        assertEq(
            amb.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrantCall.selector)
        );
        assertEq(router.getClaim(id).amount, 3 ether);
        assertEq(amb.submissions(), 1);
        assertEq(foreign.nonce(), 1);
    }

    function testFuzzCallerFundingPreservesExistingBalances(
        uint128 amountSeed,
        uint128 routerBalanceSeed,
        uint128 bridgeBalanceSeed,
        address receiver,
        uint256 minimum
    ) external {
        uint256 amount = bound(amountSeed, 1, 1e30);
        uint256 routerBalance = bound(routerBalanceSeed, 0, 1e30);
        uint256 bridgeBalance = bound(bridgeBalanceSeed, 0, 1e30);
        if (receiver == address(0)) receiver = address(1);
        usds.mint(address(router), routerBalance);
        usds.mint(address(foreign), bridgeBalance);
        usds.mint(payer, amount);
        vm.prank(payer);
        usds.approve(address(router), amount);
        vm.prank(payer);
        (bytes32 id, uint256 assets) = router.bridgeTo(receiver, amount, minimum);
        VaultClaimLib.Claim memory claim = router.getClaim(id);
        assertEq(claim.payer, payer);
        assertEq(claim.recipient, receiver);
        assertEq(claim.amount, amount);
        assertEq(claim.minShares, minimum);
        assertEq(assets, amount);
        assertEq(usds.balanceOf(payer), 0);
        assertEq(usds.balanceOf(address(router)), routerBalance);
        assertEq(usds.balanceOf(address(foreign)), bridgeBalance + amount);
        assertEq(usds.allowance(address(router), address(foreign)), 0);
        assertEq(foreign.lastReceiver(), vault);
    }

    function testFuzzSavingsUsesRedeemedAssets(
        uint128 sharesSeed,
        uint8 rateSeed,
        uint128 existingBalanceSeed,
        uint256 minimum
    ) external {
        uint256 shares = bound(sharesSeed, 1, 1e25);
        uint256 rate = bound(rateSeed, 1, 10);
        uint256 existingBalance = bound(existingBalanceSeed, 0, 1e30);
        susds.setAssetsPerShare(rate);
        _fundSavings(shares);
        usds.mint(address(router), existingBalance);
        vm.prank(payer);
        (bytes32 id, uint256 assets) = router.bridgeSavingsUSDSTo(recipient, shares, minimum);
        assertEq(assets, shares * rate);
        assertEq(router.getClaim(id).amount, shares * rate);
        assertEq(router.getClaim(id).minShares, minimum);
        assertEq(susds.balanceOf(payer), 0);
        assertEq(usds.balanceOf(address(router)), existingBalance);
        assertEq(usds.balanceOf(address(foreign)), shares * rate);
    }

    function testFuzzSourceFailureIsAtomic(
        uint128 amountSeed,
        uint128 oldBalanceSeed,
        uint8 failureSeed,
        bool savings
    ) external {
        uint256 amount = bound(amountSeed, 1, 1e30);
        uint256 oldBalance = bound(oldBalanceSeed, 0, 1e30);
        usds.mint(address(router), oldBalance);
        usds.mint(address(foreign), oldBalance);
        if (savings) {
            _fundSavings(amount);
        } else {
            usds.mint(payer, amount);
            vm.prank(payer);
            usds.approve(address(router), amount);
        }
        uint256 failure = uint256(failureSeed) % 4;
        if (failure == 0) foreign.setRejectRelay(true);
        else if (failure == 1) foreign.setNonceDelta(0);
        else if (failure == 2) foreign.setPullShort(true);
        else amb.setRejectSubmission(true);
        bytes32 id = VaultClaimLib.id(
            address(router), address(foreign), address(0x5678), vault, bytes32(0)
        );
        vm.expectRevert();
        vm.prank(payer);
        if (savings) router.bridgeSavingsUSDSTo(recipient, amount, 0);
        else router.bridgeTo(recipient, amount, 0);
        assertEq(savings ? susds.balanceOf(payer) : usds.balanceOf(payer), amount);
        assertEq(
            savings
                ? susds.allowance(payer, address(router))
                : usds.allowance(payer, address(router)),
            amount
        );
        assertEq(usds.balanceOf(address(router)), oldBalance);
        assertEq(usds.balanceOf(address(foreign)), oldBalance);
        assertEq(foreign.nonce(), 0);
        assertEq(amb.submissions(), 0);
        assertEq(usds.allowance(address(router), address(foreign)), 0);
        assertEq(router.getClaim(id).payer, address(0));
    }

    function testFuzzAnotherWalletCannotUsePayerApproval(address attacker, uint128 amountSeed)
        external
    {
        vm.assume(attacker != payer && attacker != address(router) && attacker != address(foreign));
        uint256 amount = bound(amountSeed, 1, 1e30);
        usds.mint(payer, amount);
        usds.mint(address(router), amount);
        vm.prank(payer);
        usds.approve(address(router), amount);
        vm.expectRevert();
        vm.prank(attacker);
        router.bridgeTo(attacker == address(0) ? address(1) : attacker, amount, 0);
        assertEq(usds.balanceOf(payer), amount);
        assertEq(usds.allowance(payer, address(router)), amount);
        assertEq(usds.balanceOf(address(router)), amount);
        assertEq(foreign.nonce(), 0);
        assertEq(amb.submissions(), 0);
    }
}
