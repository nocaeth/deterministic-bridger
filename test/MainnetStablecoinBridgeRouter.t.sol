// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { SavingsXDaiReceiver } from "../src/SavingsXDaiReceiver.sol";
import { SavingsXDaiReceiverFactory } from "../src/SavingsXDaiReceiverFactory.sol";
import { MainnetStablecoinBridgeRouter } from "../src/MainnetStablecoinBridgeRouter.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IXDaiBridge } from "../src/interfaces/IXDaiBridge.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";
import { MockAdapter } from "./mocks/MockAdapter.sol";
import { MockERC4626 } from "./mocks/MockERC4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockXDaiBridge } from "./mocks/MockXDaiBridge.sol";

contract MainnetStablecoinBridgeRouterTest is Test {
    event BridgeRequested(
        address indexed payer,
        address indexed deterministicReceiver,
        address indexed gnosisReceiver,
        uint256 amount
    );

    MockERC20 internal mainnetToken;
    MockERC4626 internal savingsUSDS;
    MockXDaiBridge internal bridge;
    SavingsXDaiReceiverFactory internal factory;
    SavingsXDaiReceiver internal singleton;
    MainnetStablecoinBridgeRouter internal router;

    address internal payer = address(0xB0B);
    address internal receiver = address(0xA11CE);

    function setUp() external {
        _installTokenMocks();
        bridge = new MockXDaiBridge(IERC20(ChainConstants.ETHEREUM_USDS));
        singleton = new SavingsXDaiReceiver(new MockAdapter());
        factory = new SavingsXDaiReceiverFactory(address(singleton));
        router = new MainnetStablecoinBridgeRouter(
            IXDaiBridge(address(bridge)), address(factory), address(singleton)
        );
    }

    function testRouterUsesHardcodedMainnetAssets() external view {
        assertEq(router.MAINNET_TOKEN(), ChainConstants.ETHEREUM_USDS, "USDS constant");
        assertEq(router.SAVINGS_USDS(), ChainConstants.ETHEREUM_SUSDS, "sUSDS constant");
        assertEq(address(router.mainnetToken()), ChainConstants.ETHEREUM_USDS, "USDS getter");
        assertEq(address(router.savingsUSDS()), ChainConstants.ETHEREUM_SUSDS, "sUSDS getter");
    }

    function testReceiverForMatchesFactoryPrediction() external view {
        assertEq(router.receiverFor(receiver), factory.predict(receiver), "receiver prediction");
    }

    function testConstructorRevertsOnZeroBridge() external {
        vm.expectRevert(MainnetStablecoinBridgeRouter.InvalidConfig.selector);
        new MainnetStablecoinBridgeRouter(
            IXDaiBridge(address(0)), address(factory), address(singleton)
        );
    }

    function testConstructorRevertsOnZeroFactory() external {
        vm.expectRevert(MainnetStablecoinBridgeRouter.InvalidConfig.selector);
        new MainnetStablecoinBridgeRouter(
            IXDaiBridge(address(bridge)), address(0), address(singleton)
        );
    }

    function testConstructorRevertsOnZeroSingleton() external {
        vm.expectRevert(MainnetStablecoinBridgeRouter.InvalidConfig.selector);
        new MainnetStablecoinBridgeRouter(
            IXDaiBridge(address(bridge)), address(factory), address(0)
        );
    }

    function testBridgeToDerivesReceiverFromReceiverNotPayer() external {
        uint256 amount = 100 ether;
        address expectedReceiver = factory.predict(receiver);
        mainnetToken.mint(payer, amount);

        vm.prank(payer);
        mainnetToken.approve(address(router), amount);

        vm.expectEmit(true, true, true, true, address(router));
        emit BridgeRequested(payer, receiver, expectedReceiver, amount);

        vm.prank(payer);
        address gnosisReceiver = router.bridgeTo(receiver, amount);

        assertEq(gnosisReceiver, expectedReceiver, "receiver");
        assertEq(bridge.lastCaller(), address(router), "bridge caller");
        assertEq(bridge.lastReceiver(), expectedReceiver, "bridge receiver");
        assertEq(bridge.lastAmount(), amount, "bridge amount");
        assertEq(mainnetToken.balanceOf(address(bridge)), amount, "bridged token");
        assertEq(mainnetToken.allowance(address(router), address(bridge)), 0, "bridge allowance");
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

    function testBridgeSavingsUSDSToRedeemsAndBridgesUsds() external {
        uint256 shares = 4 ether;
        uint256 assetsPerShare = 2;
        uint256 expectedAmount = shares * assetsPerShare;
        address expectedReceiver = factory.predict(receiver);
        savingsUSDS.setAssetsPerShare(assetsPerShare);
        savingsUSDS.mint(payer, shares);

        vm.prank(payer);
        savingsUSDS.approve(address(router), shares);

        vm.expectEmit(true, true, true, true, address(router));
        emit BridgeRequested(payer, receiver, expectedReceiver, expectedAmount);

        vm.prank(payer);
        (address gnosisReceiver, uint256 amount) = router.bridgeSavingsUSDSTo(receiver, shares);

        assertEq(gnosisReceiver, expectedReceiver, "receiver");
        assertEq(amount, expectedAmount, "redeemed assets");
        assertEq(savingsUSDS.balanceOf(payer), 0, "shares burned");
        assertEq(mainnetToken.balanceOf(address(bridge)), expectedAmount, "bridged USDS");
        assertEq(bridge.lastReceiver(), expectedReceiver, "bridge receiver");
        assertEq(bridge.lastAmount(), expectedAmount, "bridge amount");
    }

    function testBridgeSavingsUSDSDefaultsReceiverToPayer() external {
        uint256 shares = 6 ether;
        address expectedReceiver = factory.predict(payer);
        savingsUSDS.mint(payer, shares);

        vm.prank(payer);
        savingsUSDS.approve(address(router), shares);

        vm.prank(payer);
        (address gnosisReceiver, uint256 amount) = router.bridgeSavingsUSDS(shares);

        assertEq(gnosisReceiver, expectedReceiver, "receiver");
        assertEq(amount, shares, "redeemed assets");
        assertEq(bridge.lastReceiver(), expectedReceiver, "bridge receiver");
    }

    function testBridgeSavingsUSDSRevertsOnZeroShares() external {
        vm.expectRevert(MainnetStablecoinBridgeRouter.InvalidAmount.selector);
        router.bridgeSavingsUSDSTo(receiver, 0);
    }

    function testBridgeSavingsUSDSRevertsOnZeroReceiver() external {
        vm.expectRevert(MainnetStablecoinBridgeRouter.InvalidReceiver.selector);
        router.bridgeSavingsUSDSTo(address(0), 1);
    }

    function testBridgeSavingsUSDSRevertsWhenRedeemReturnsZeroAssets() external {
        uint256 shares = 1 ether;
        savingsUSDS.setAssetsPerShare(0);
        savingsUSDS.mint(payer, shares);

        vm.prank(payer);
        savingsUSDS.approve(address(router), shares);

        vm.prank(payer);
        vm.expectRevert(MainnetStablecoinBridgeRouter.InvalidAmount.selector);
        router.bridgeSavingsUSDSTo(receiver, shares);
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

    function testFuzzSavingsUSDSReceiverMatchesFactory(
        address fuzzPayer,
        address fuzzReceiver,
        uint96 shares
    ) external {
        vm.assume(fuzzPayer != address(0));
        vm.assume(fuzzReceiver != address(0));
        vm.assume(shares > 0);

        savingsUSDS.mint(fuzzPayer, shares);

        vm.prank(fuzzPayer);
        savingsUSDS.approve(address(router), shares);

        vm.prank(fuzzPayer);
        (address gnosisReceiver, uint256 amount) = router.bridgeSavingsUSDSTo(fuzzReceiver, shares);

        assertEq(gnosisReceiver, factory.predict(fuzzReceiver), "receiver");
        assertEq(amount, shares, "redeemed assets");
        assertEq(bridge.lastReceiver(), gnosisReceiver, "bridge receiver");
    }

    function _installTokenMocks() private {
        MockERC20 mainnetTokenImplementation = new MockERC20();
        vm.etch(ChainConstants.ETHEREUM_USDS, address(mainnetTokenImplementation).code);
        mainnetToken = MockERC20(ChainConstants.ETHEREUM_USDS);

        MockERC4626 savingsUSDSImplementation = new MockERC4626(mainnetToken);
        vm.etch(ChainConstants.ETHEREUM_SUSDS, address(savingsUSDSImplementation).code);
        savingsUSDS = MockERC4626(ChainConstants.ETHEREUM_SUSDS);
        savingsUSDS.setAssetsPerShare(1);
    }
}
