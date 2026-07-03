// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { SavingsXDaiReceiver } from "../src/SavingsXDaiReceiver.sol";
import { SavingsXDaiReceiverFactory } from "../src/SavingsXDaiReceiverFactory.sol";
import { MainnetStablecoinBridgeRouter } from "../src/MainnetStablecoinBridgeRouter.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IXDaiBridge } from "../src/interfaces/IXDaiBridge.sol";
import { MockAdapter } from "./mocks/MockAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockXDaiBridge } from "./mocks/MockXDaiBridge.sol";

contract MainnetStablecoinBridgeRouterTest is Test {
    MockERC20 internal mainnetToken;
    MockXDaiBridge internal bridge;
    SavingsXDaiReceiverFactory internal factory;
    SavingsXDaiReceiver internal singleton;
    MainnetStablecoinBridgeRouter internal router;

    address internal payer = address(0xB0B);
    address internal receiver = address(0xA11CE);

    function setUp() external {
        mainnetToken = new MockERC20();
        bridge = new MockXDaiBridge(IERC20(address(mainnetToken)));
        singleton = new SavingsXDaiReceiver(new MockAdapter());
        factory = new SavingsXDaiReceiverFactory(address(singleton));
        router = new MainnetStablecoinBridgeRouter(
            IERC20(address(mainnetToken)),
            IXDaiBridge(address(bridge)),
            address(factory),
            address(singleton)
        );
    }

    function testBridgeToDerivesReceiverFromReceiverNotPayer() external {
        uint256 amount = 100 ether;
        address expectedReceiver = factory.predict(receiver);
        mainnetToken.mint(payer, amount);

        vm.prank(payer);
        mainnetToken.approve(address(router), amount);

        vm.prank(payer);
        address gnosisReceiver = router.bridgeTo(receiver, amount);

        assertEq(gnosisReceiver, expectedReceiver, "receiver");
        assertEq(bridge.lastCaller(), address(router), "bridge caller");
        assertEq(bridge.lastReceiver(), expectedReceiver, "bridge receiver");
        assertEq(bridge.lastAmount(), amount, "bridge amount");
        assertEq(mainnetToken.balanceOf(address(bridge)), amount, "bridged token");
    }

    function testRepeatedBridgeDepositsUseSameRecipient() external {
        uint256 firstAmount = 7 ether;
        uint256 secondAmount = 11 ether;
        address expectedReceiver = factory.predict(receiver);
        mainnetToken.mint(payer, firstAmount + secondAmount);

        vm.prank(payer);
        mainnetToken.approve(address(router), firstAmount + secondAmount);

        vm.prank(payer);
        address firstReceiver = router.bridgeTo(receiver, firstAmount);

        vm.prank(payer);
        address secondReceiver = router.bridgeTo(receiver, secondAmount);

        assertEq(firstReceiver, expectedReceiver, "first receiver");
        assertEq(secondReceiver, expectedReceiver, "second receiver");
        assertEq(bridge.totalAmount(), firstAmount + secondAmount, "total amount");
        assertEq(bridge.callCount(), 2, "bridge calls");
    }

    function testBridgeRevertsOnZeroAmount() external {
        vm.expectRevert(MainnetStablecoinBridgeRouter.InvalidAmount.selector);
        router.bridgeTo(receiver, 0);
    }

    function testBridgeRevertsOnZeroReceiver() external {
        vm.expectRevert(MainnetStablecoinBridgeRouter.InvalidReceiver.selector);
        router.bridgeTo(address(0), 1);
    }

    function testBridgeDefaultsReceiverToPayer() external {
        uint256 amount = 5 ether;
        address expectedReceiver = factory.predict(payer);
        mainnetToken.mint(payer, amount);

        vm.prank(payer);
        mainnetToken.approve(address(router), amount);

        vm.prank(payer);
        address gnosisReceiver = router.bridge(amount);

        assertEq(gnosisReceiver, expectedReceiver, "receiver");
        assertEq(bridge.lastReceiver(), expectedReceiver, "bridge receiver");
    }

    function testFuzzRouterReceiverMatchesFactory(
        address fuzzPayer,
        address fuzzReceiver,
        uint96 amount
    ) external {
        vm.assume(fuzzPayer != address(0));
        vm.assume(fuzzReceiver != address(0));
        vm.assume(amount > 0);

        mainnetToken.mint(fuzzPayer, amount);

        vm.prank(fuzzPayer);
        mainnetToken.approve(address(router), amount);

        vm.prank(fuzzPayer);
        address gnosisReceiver = router.bridgeTo(fuzzReceiver, amount);

        assertEq(gnosisReceiver, factory.predict(fuzzReceiver), "receiver");
        assertEq(bridge.lastReceiver(), gnosisReceiver, "bridge receiver");
    }
}
