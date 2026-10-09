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
}
