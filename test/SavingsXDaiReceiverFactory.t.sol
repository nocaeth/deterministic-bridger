// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { SavingsXDaiReceiver } from "../src/SavingsXDaiReceiver.sol";
import { SavingsXDaiReceiverFactory } from "../src/SavingsXDaiReceiverFactory.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { MockAdapter } from "./mocks/MockAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract SavingsXDaiReceiverFactoryTest is Test {
    event Deployed(address indexed deterministicReceiver, address indexed receiver);

    MockAdapter internal adapter;
    SavingsXDaiReceiver internal singleton;
    SavingsXDaiReceiverFactory internal factory;

    address internal sender = address(0xA11CE);

    function setUp() external {
        adapter = new MockAdapter();
        singleton = new SavingsXDaiReceiver(adapter);
        factory = new SavingsXDaiReceiverFactory(address(singleton));
    }

    function testPredictMatchesDeployedProxy() external {
        address predicted = factory.predict(sender);

        vm.expectEmit(true, true, false, true, address(factory));
        emit Deployed(sender, predicted);

        address deployed = factory.deploy(sender);

        assertEq(deployed, predicted, "deployed recipient");
        assertEq(
            SavingsXDaiReceiver(payable(deployed)).deterministicReceiver(), sender, "bound receiver"
        );
        assertTrue(deployed.code.length != 0, "recipient should have code");
    }

    function testFactoryRevertsWhenSingletonIsZero() external {
        vm.expectRevert(SavingsXDaiReceiverFactory.InvalidSingleton.selector);
        new SavingsXDaiReceiverFactory(address(0));
    }

    function testFactoryRevertsWhenSingletonHasNoCode() external {
        vm.expectRevert(SavingsXDaiReceiverFactory.InvalidSingleton.selector);
        new SavingsXDaiReceiverFactory(address(0x1234));
    }

    function testPredictUniquePerSender() external view {
        address first = factory.predict(address(0xA));
        address second = factory.predict(address(0xB));

        assertTrue(first != second, "recipients should differ");
    }

    function testFactoryCallerDoesNotInfluenceReceiverAddress() external {
        address firstCaller = address(0xC011A);
        address secondCaller = address(0xC011B);
        address predicted = factory.predict(sender);

        vm.prank(firstCaller);
        address deployed = factory.deploy(sender);

        vm.prank(secondCaller);
        address deployedAgain = factory.deploy(sender);

        assertEq(deployed, predicted, "first caller deployed address");
        assertEq(deployedAgain, predicted, "second caller deployed address");
        assertEq(
            SavingsXDaiReceiver(payable(deployed)).deterministicReceiver(), sender, "bound receiver"
        );
    }

    function testFactoryCallerNonceDoesNotInfluenceReceiverAddress() external {
        FactoryCaller caller = new FactoryCaller();
        address predicted = factory.predict(sender);

        caller.burnNonce(5);
        uint64 nonceBefore = vm.getNonce(address(caller));
        address deployed = caller.deploy(factory, sender);

        assertEq(deployed, predicted, "deployed address");
        assertEq(vm.getNonce(address(caller)), nonceBefore, "factory call nonce");
        assertEq(
            SavingsXDaiReceiver(payable(deployed)).deterministicReceiver(), sender, "bound receiver"
        );

        address otherReceiver = address(0xBEEF);
        address otherPredicted = factory.predict(otherReceiver);
        caller.burnNonce(3);
        assertGt(vm.getNonce(address(caller)), nonceBefore, "caller nonce should change");

        address otherDeployed = caller.deploy(factory, otherReceiver);

        assertEq(otherDeployed, otherPredicted, "other deployed address");
        assertEq(
            SavingsXDaiReceiver(payable(otherDeployed)).deterministicReceiver(),
            otherReceiver,
            "other bound receiver"
        );
    }

    function testFactoryNonceDoesNotInfluenceReceiverPrediction() external {
        address predictedBefore = factory.predict(sender);
        uint64 nonceBefore = vm.getNonce(address(factory));

        factory.deploy(address(0xA));
        factory.deploy(address(0xB));

        assertGt(vm.getNonce(address(factory)), nonceBefore, "factory nonce should change");
        assertEq(factory.predict(sender), predictedBefore, "prediction after nonce change");

        address deployed = factory.deploy(sender);

        assertEq(deployed, predictedBefore, "deployed address");
        assertEq(
            SavingsXDaiReceiver(payable(deployed)).deterministicReceiver(), sender, "bound receiver"
        );
    }

    function testCounterfactualFundingConvertsDuringDeployment() external {
        address predicted = factory.predict(sender);
        vm.deal(predicted, 5 ether);

        assertEq(predicted.balance, 5 ether, "prefund balance");

        address deployed = factory.deploy(sender);

        assertEq(deployed, predicted, "deployed recipient");
        assertEq(deployed.balance, 0, "post-deploy balance");
        assertEq(adapter.lastReceiver(), sender, "receiver");
        assertEq(adapter.lastValue(), 5 ether, "deposit value");
        assertEq(adapter.sharesOf(sender), 5 ether, "receiver shares");
    }

    function testDeployAndConvertConvertsFullBalance() external {
        address predicted = factory.predict(sender);
        vm.deal(predicted, 3 ether);

        (address recipient, uint256 shares) = factory.deployAndConvert(sender);

        assertEq(recipient, predicted, "recipient");
        assertEq(shares, 3 ether, "shares");
        assertEq(recipient.balance, 0, "recipient balance");
        assertEq(adapter.lastReceiver(), sender, "receiver");
        assertEq(adapter.lastValue(), 3 ether, "deposit value");
        assertEq(adapter.sharesOf(sender), 3 ether, "receiver shares");
    }

    function testDeployWithNoBalanceDoesNotCallAdapter() external {
        address recipient = factory.deploy(sender);

        assertEq(recipient.balance, 0, "recipient balance");
        assertEq(adapter.callCount(), 0, "adapter calls");
    }

    function testSetUpRevertsWhenDeterministicReceiverIsZero() external {
        vm.expectRevert(SavingsXDaiReceiver.InvalidDeterministicReceiver.selector);
        singleton.setUp(address(0));
    }

    function testSetUpRevertsWhenAlreadyInitialized() external {
        address recipient = factory.deploy(sender);

        vm.expectRevert(SavingsXDaiReceiver.AlreadyInitialized.selector);
        SavingsXDaiReceiver(payable(recipient)).setUp(address(0xBEEF));
    }

    function testReceiveConvertsFullBalance() external {
        address recipient = factory.deploy(sender);
        vm.deal(address(this), 6 ether);

        (bool success,) = payable(recipient).call{ value: 6 ether }("");

        assertTrue(success, "receive should convert");
        assertEq(recipient.balance, 0, "recipient balance");
        assertEq(adapter.lastReceiver(), sender, "receiver");
        assertEq(adapter.lastValue(), 6 ether, "deposit value");
        assertEq(adapter.sharesOf(sender), 6 ether, "receiver shares");
    }

    function testDeployAndConvertWorksAfterSeparateDeployment() external {
        address recipient = factory.deploy(sender);
        vm.deal(recipient, 4 ether);

        (address deployedAgain, uint256 shares) = factory.deployAndConvert(sender);

        assertEq(deployedAgain, recipient, "recipient");
        assertEq(shares, 4 ether, "shares");
        assertEq(adapter.callCount(), 1, "adapter calls");
    }

    function testConvertZeroBalanceReturnsCleanly() external {
        address recipient = factory.deploy(sender);

        uint256 shares = SavingsXDaiReceiver(payable(recipient)).convertToSavingsXDai();

        assertEq(shares, 0, "shares");
        assertEq(adapter.callCount(), 0, "adapter calls");
    }

    function testConvertRevertsWhenFundedButUninitialized() external {
        vm.deal(address(singleton), 1 ether);

        vm.expectRevert(SavingsXDaiReceiver.NotInitialized.selector);
        singleton.convertToSavingsXDai();
    }

    function testAdapterRevertLeavesBalanceForRetry() external {
        address recipient = factory.deploy(sender);
        vm.deal(recipient, 2 ether);
        adapter.setShouldRevert(true);

        vm.expectRevert(MockAdapter.DepositFailed.selector);
        SavingsXDaiReceiver(payable(recipient)).convertToSavingsXDai();

        assertEq(recipient.balance, 2 ether, "balance after failed convert");

        adapter.setShouldRevert(false);
        uint256 shares = SavingsXDaiReceiver(payable(recipient)).convertToSavingsXDai();

        assertEq(shares, 2 ether, "retry shares");
        assertEq(recipient.balance, 0, "balance after retry");
    }

    function testDeployAutoConvertRevertLeavesCounterfactualBalanceForRetry() external {
        address predicted = factory.predict(sender);
        vm.deal(predicted, 2 ether);
        adapter.setShouldRevert(true);

        vm.expectRevert(MockAdapter.DepositFailed.selector);
        factory.deploy(sender);

        assertEq(predicted.balance, 2 ether, "balance after failed deploy");
        assertEq(predicted.code.length, 0, "code after failed deploy");

        adapter.setShouldRevert(false);
        address deployed = factory.deploy(sender);

        assertEq(deployed, predicted, "deployed recipient");
        assertEq(deployed.balance, 0, "balance after retry");
        assertEq(adapter.sharesOf(sender), 2 ether, "receiver shares");
    }

    function testMoveERC20ToReceiverSendsFullBalanceToBoundReceiver() external {
        MockERC20 token = new MockERC20();
        address recipient = factory.deploy(sender);
        address caller = address(0xBAD);
        token.mint(recipient, 13 ether);

        vm.prank(caller);
        uint256 amount =
            SavingsXDaiReceiver(payable(recipient)).moveERC20ToReceiver(IERC20(address(token)));

        assertEq(amount, 13 ether, "amount moved");
        assertEq(token.balanceOf(recipient), 0, "recipient token balance");
        assertEq(token.balanceOf(sender), 13 ether, "bound receiver token balance");
        assertEq(token.balanceOf(caller), 0, "caller token balance");
    }

    function testMoveERC20ZeroBalanceReturnsCleanly() external {
        MockERC20 token = new MockERC20();
        address recipient = factory.deploy(sender);

        uint256 amount =
            SavingsXDaiReceiver(payable(recipient)).moveERC20ToReceiver(IERC20(address(token)));

        assertEq(amount, 0, "amount moved");
        assertEq(token.balanceOf(sender), 0, "receiver token balance");
    }

    function testMoveERC20RevertsWhenFundedButUninitialized() external {
        MockERC20 token = new MockERC20();
        token.mint(address(singleton), 1 ether);

        vm.expectRevert(SavingsXDaiReceiver.NotInitialized.selector);
        singleton.moveERC20ToReceiver(IERC20(address(token)));
    }

    function testFuzzPredictUnique(address firstSender, address secondSender) external view {
        vm.assume(firstSender != address(0));
        vm.assume(secondSender != address(0));
        vm.assume(firstSender != secondSender);

        assertTrue(
            factory.predict(firstSender) != factory.predict(secondSender),
            "fuzz recipients should differ"
        );
    }

    function testFuzzRepeatConvert(address fuzzSender, uint96 firstAmount, uint96 secondAmount)
        external
    {
        vm.assume(fuzzSender != address(0));

        address recipient = factory.deploy(fuzzSender);
        uint256 amountA = uint256(firstAmount);
        uint256 amountB = uint256(secondAmount);

        vm.deal(recipient, amountA);
        uint256 sharesA = SavingsXDaiReceiver(payable(recipient)).convertToSavingsXDai();

        vm.deal(recipient, amountB);
        uint256 sharesB = SavingsXDaiReceiver(payable(recipient)).convertToSavingsXDai();

        assertEq(sharesA, amountA, "first shares");
        assertEq(sharesB, amountB, "second shares");
        assertEq(recipient.balance, 0, "recipient balance");
        assertEq(adapter.totalValue(), amountA + amountB, "total deposited");
        assertEq(adapter.sharesOf(fuzzSender), amountA + amountB, "receiver shares");
    }
}

contract FactoryCaller {
    function burnNonce(uint256 count) external {
        for (uint256 i; i < count; i++) {
            new NonceBurner();
        }
    }

    function deploy(SavingsXDaiReceiverFactory factory, address deterministicReceiver)
        external
        returns (address receiver)
    {
        receiver = factory.deploy(deterministicReceiver);
    }
}

contract NonceBurner { }
