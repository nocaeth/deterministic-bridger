// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { SafeERC20 } from "../src/libraries/SafeERC20.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract SafeERC20Harness {
    using SafeERC20 for IERC20;

    function approve(IERC20 token, address spender, uint256 amount) external {
        token.safeApprove(spender, amount);
    }

    function transfer(IERC20 token, address recipient, uint256 amount) external {
        token.safeTransfer(recipient, amount);
    }

    function transferFrom(IERC20 token, address payer, address recipient, uint256 amount) external {
        token.safeTransferFrom(payer, recipient, amount);
    }
}

contract ReturnDataToken {
    bytes private returnData;
    bool private rejectCall;

    constructor(bytes memory returnData_, bool rejectCall_) {
        returnData = returnData_;
        rejectCall = rejectCall_;
    }

    fallback() external {
        if (rejectCall) revert();
        bytes memory data = returnData;
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }
}

contract SafeERC20Test is Test {
    SafeERC20Harness private harness;
    address private recipient = address(0xA11CE);

    function setUp() public {
        harness = new SafeERC20Harness();
    }

    function testBooleanReturningTokenPreservesTransfersAndAllowance() external {
        MockERC20 token = new MockERC20();
        token.mint(address(harness), 7);
        harness.approve(IERC20(address(token)), recipient, 3);
        assertEq(token.allowance(address(harness), recipient), 3);
        harness.transfer(IERC20(address(token)), recipient, 2);
        token.mint(address(this), 5);
        token.approve(address(harness), 5);
        harness.transferFrom(IERC20(address(token)), address(this), recipient, 4);
        assertEq(token.balanceOf(recipient), 6);
        assertEq(token.balanceOf(address(harness)), 5);
        assertEq(token.balanceOf(address(this)), 1);
        assertEq(token.allowance(address(this), address(harness)), 1);
    }

    function testNoReturnContractIsSupportedForAllOperations() external {
        IERC20 token = IERC20(address(new ReturnDataToken("", false)));
        harness.approve(token, recipient, 1);
        harness.transfer(token, recipient, 1);
        harness.transferFrom(token, address(this), recipient, 1);
    }

    function testAddressWithoutCodeIsRejectedForAllOperations() external {
        IERC20 token = IERC20(address(0xBEEF));
        vm.expectRevert(SafeERC20.SafeERC20CallFailed.selector);
        harness.approve(token, recipient, 1);
        vm.expectRevert(SafeERC20.SafeERC20CallFailed.selector);
        harness.transfer(token, recipient, 1);
        vm.expectRevert(SafeERC20.SafeERC20CallFailed.selector);
        harness.transferFrom(token, address(this), recipient, 1);
    }

    function testRevertedTokenCallUsesWrapperError() external {
        IERC20 token = IERC20(address(new ReturnDataToken("", true)));
        vm.expectRevert(SafeERC20.SafeERC20CallFailed.selector);
        harness.transfer(token, recipient, 1);
    }

    function testFuzzInvalidBooleanReturnUsesWrapperError(uint256 returnValue) external {
        vm.assume(returnValue != 1);
        IERC20 token = IERC20(address(new ReturnDataToken(abi.encode(returnValue), false)));
        vm.expectRevert(SafeERC20.SafeERC20CallFailed.selector);
        harness.transfer(token, recipient, 1);
    }

    function testFuzzShortReturnUsesWrapperError(uint8 length) external {
        bytes memory data = new bytes(bound(length, 1, 31));
        IERC20 token = IERC20(address(new ReturnDataToken(data, false)));
        vm.expectRevert(SafeERC20.SafeERC20CallFailed.selector);
        harness.transfer(token, recipient, 1);
    }
}
