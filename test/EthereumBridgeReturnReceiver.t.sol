// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { EthereumBridgeReturnReceiver as Receiver } from "../src/EthereumBridgeReturnReceiver.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract EthereumBridgeReturnReceiverTest is Test {
    Receiver internal receiver;
    MockERC20 internal usds;
    MockERC20 internal dai;
    address internal authority = address(0xA11CE);
    address internal payer = address(0xB0B);

    function setUp() public {
        vm.chainId(1);
        vm.etch(ChainConstants.ETHEREUM_USDS, address(new MockERC20()).code);
        vm.etch(ChainConstants.ETHEREUM_DAI, address(new MockERC20()).code);
        usds = MockERC20(ChainConstants.ETHEREUM_USDS);
        dai = MockERC20(ChainConstants.ETHEREUM_DAI);
        receiver = new Receiver(authority);
    }

    function testOnlyAuthorityCanReturnCanonicalAssets() external {
        usds.mint(address(receiver), 5 ether);
        dai.mint(address(receiver), 3 ether);
        vm.expectRevert(Receiver.Unauthorized.selector);
        receiver.recover(address(usds), payer, 1 ether);
        vm.startPrank(authority);
        receiver.recover(address(usds), payer, 5 ether);
        receiver.recover(address(dai), payer, 3 ether);
        vm.stopPrank();
        assertEq(usds.balanceOf(payer), 5 ether);
        assertEq(dai.balanceOf(payer), 3 ether);
    }

    function testCannotSweepAnotherTokenOrInvalidRecipient() external {
        vm.startPrank(authority);
        vm.expectRevert(Receiver.InvalidRecovery.selector);
        receiver.recover(address(0x1234), payer, 1);
        vm.expectRevert(Receiver.InvalidRecovery.selector);
        receiver.recover(address(usds), address(0), 1);
        vm.expectRevert(Receiver.InvalidRecovery.selector);
        receiver.recover(address(usds), payer, 0);
        vm.stopPrank();
    }

    function testRejectsWrongChainAndZeroAuthority() external {
        vm.expectRevert(Receiver.InvalidRecovery.selector);
        new Receiver(address(0));
        vm.chainId(100);
        vm.expectRevert(Receiver.InvalidRecovery.selector);
        new Receiver(authority);
    }
}
