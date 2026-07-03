// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script } from "forge-std/Script.sol";
import { SavingsXDaiReceiverFactory } from "../src/SavingsXDaiReceiverFactory.sol";

/// @notice Permissionless script entry point for deploying and converting a receiver.
contract WatchtowerDeployAndConvert is Script {
    /// @notice Calls `deployAndConvert` for `DETERMINISTIC_RECEIVER` on Gnosis.
    /// @return receiver Deterministic receiver clone.
    /// @return shares sDAI shares reported by the adapter.
    function run() external returns (address receiver, uint256 shares) {
        SavingsXDaiReceiverFactory factory =
            SavingsXDaiReceiverFactory(vm.envAddress("SAVINGS_XDAI_RECEIVER_FACTORY"));
        address deterministicReceiver = vm.envAddress("DETERMINISTIC_RECEIVER");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);
        (receiver, shares) = factory.deployAndConvert(deterministicReceiver);
        vm.stopBroadcast();
    }
}
