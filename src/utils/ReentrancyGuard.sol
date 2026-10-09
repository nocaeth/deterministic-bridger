// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Prevents nested calls to protected state-changing functions.
abstract contract ReentrancyGuard {
    error ReentrantCall();

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private reentrancyStatus = NOT_ENTERED;

    modifier nonReentrant() {
        _requireNotEntered();
        reentrancyStatus = ENTERED;
        _;
        reentrancyStatus = NOT_ENTERED;
    }

    function _requireNotEntered() internal view {
        if (reentrancyStatus == ENTERED) revert ReentrantCall();
    }
}
