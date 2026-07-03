// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "./interfaces/IERC20.sol";
import { ISavingsXDaiAdapter } from "./interfaces/ISavingsXDaiAdapter.sol";
import { SafeERC20 } from "./libraries/SafeERC20.sol";

/// @title SavingsXDaiReceiver
/// @notice Deterministic Gnosis receiver that converts all received xDAI into sDAI.
/// @dev Clones are bound once to a deterministic receiver. Anyone may call conversion, adapter
///      failures revert and leave xDAI in the receiver. ERC-20 recovery can only move tokens
///      to the bound deterministic receiver, and no admin-controlled sweep path exists.
contract SavingsXDaiReceiver {
    using SafeERC20 for IERC20;

    /// @notice Reverts when a clone is initialized more than once.
    error AlreadyInitialized();

    /// @notice Reverts when the bound deterministic receiver is the zero address.
    error InvalidDeterministicReceiver();

    /// @notice Reverts when a funded implementation or uninitialized clone is converted.
    error NotInitialized();

    /// @notice Emitted when a clone is bound to its deterministic receiver.
    /// @param deterministicReceiver Address that receives sDAI shares from conversions.
    event SetUp(address indexed deterministicReceiver);

    /// @notice Emitted after xDAI is deposited into the configured Savings xDAI adapter.
    /// @param deterministicReceiver Address that received the sDAI shares.
    /// @param amount Native xDAI amount deposited.
    /// @param shares sDAI shares reported by the adapter.
    event ConvertedToSavingsXDai(
        address indexed deterministicReceiver, uint256 amount, uint256 shares
    );

    /// @notice Emitted after an ERC-20 balance is moved to the bound deterministic receiver.
    /// @param token ERC-20 token moved from this receiver.
    /// @param deterministicReceiver Bound receiver that received the token balance.
    /// @param amount ERC-20 amount moved.
    event ERC20MovedToReceiver(
        IERC20 indexed token, address indexed deterministicReceiver, uint256 amount
    );

    /// @notice Adapter that receives xDAI and mints or transfers sDAI shares.
    ISavingsXDaiAdapter public immutable savingsXDaiAdapter;

    /// @notice Address used as the sDAI receiver for every conversion.
    address public deterministicReceiver;

    /// @notice Creates the singleton implementation used by deterministic clones.
    /// @param savingsXDaiAdapter_ Deployment-configured adapter for xDAI to sDAI conversion.
    constructor(ISavingsXDaiAdapter savingsXDaiAdapter_) {
        savingsXDaiAdapter = savingsXDaiAdapter_;
    }

    /// @notice Accepts native xDAI bridged before or after clone deployment.
    receive() external payable {
        convertToSavingsXDai();
    }

    /// @notice Binds a newly deployed clone to its intended deterministic receiver.
    /// @param deterministicReceiver_ Address that receives sDAI shares.
    function setUp(address deterministicReceiver_) external {
        if (deterministicReceiver != address(0)) revert AlreadyInitialized();
        if (deterministicReceiver_ == address(0)) revert InvalidDeterministicReceiver();

        deterministicReceiver = deterministicReceiver_;
        emit SetUp(deterministicReceiver_);
    }

    /// @notice Converts the receiver's full xDAI balance into sDAI for `deterministicReceiver`.
    /// @dev Permissionless. If the adapter reverts, the transaction reverts and xDAI remains here.
    /// @return shares sDAI shares reported by the adapter, or zero when there is no xDAI.
    function convertToSavingsXDai() public returns (uint256 shares) {
        uint256 balance = address(this).balance;
        if (balance == 0) return 0;

        address receiver = deterministicReceiver;
        if (receiver == address(0)) revert NotInitialized();

        shares = savingsXDaiAdapter.depositXDAI{ value: balance }(receiver);

        emit ConvertedToSavingsXDai(receiver, balance, shares);
    }

    /// @notice Moves this contract's full ERC-20 balance to the bound deterministic receiver.
    /// @dev Permissionless. The caller cannot choose the destination, so tokens cannot be redirected.
    /// @param token ERC-20 token to move.
    /// @return amount ERC-20 amount moved, or zero when there is no token balance.
    function moveERC20ToReceiver(IERC20 token) external returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount == 0) return 0;

        address receiver = deterministicReceiver;
        if (receiver == address(0)) revert NotInitialized();

        token.safeTransfer(receiver, amount);

        emit ERC20MovedToReceiver(token, receiver, amount);
    }
}
