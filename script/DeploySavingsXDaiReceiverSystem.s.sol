// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script } from "forge-std/Script.sol";
import { SavingsXDaiReceiver } from "../src/SavingsXDaiReceiver.sol";
import { SavingsXDaiReceiverFactory } from "../src/SavingsXDaiReceiverFactory.sol";
import { ISavingsXDaiAdapter } from "../src/interfaces/ISavingsXDaiAdapter.sol";

/// @notice Deploys the Gnosis receiver singleton and deterministic factory.
contract DeploySavingsXDaiReceiverSystem is Script {
    /// @notice Deploys `SavingsXDaiReceiver` and `SavingsXDaiReceiverFactory`.
    /// @return singleton Receiver singleton implementation.
    /// @return factory Deterministic receiver factory.
    function run()
        external
        returns (SavingsXDaiReceiver singleton, SavingsXDaiReceiverFactory factory)
    {
        ISavingsXDaiAdapter adapter = ISavingsXDaiAdapter(vm.envAddress("SAVINGS_XDAI_ADAPTER"));
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);
        singleton = new SavingsXDaiReceiver(adapter);
        factory = new SavingsXDaiReceiverFactory(address(singleton));
        vm.stopBroadcast();
    }
}
