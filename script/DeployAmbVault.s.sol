// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script } from "forge-std/Script.sol";
import { SavingsXDaiSettlementVault } from "../src/SavingsXDaiSettlementVault.sol";
import { IHomeXDaiBridge } from "../src/interfaces/IHomeXDaiBridge.sol";
import { IAMB } from "../src/interfaces/IAMB.sol";
import { ISavingsXDaiAdapter } from "../src/interfaces/ISavingsXDaiAdapter.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";

/// @notice Deploy first, bound to the dedicated Ethereum deployer's next CREATE address.
contract DeployAmbVault is Script {
    function run() external returns (SavingsXDaiSettlementVault vault) {
        require(block.chainid == 100, "GNOSIS_ONLY");
        address expectedRouter = vm.envAddress("EXPECTED_MAINNET_AMB_ROUTER");
        IHomeXDaiBridge home =
            IHomeXDaiBridge(vm.envOr("HOME_XDAI_BRIDGE", ChainConstants.GNOSIS_XDAI_BRIDGE));
        IAMB amb = IAMB(vm.envAddress("GNOSIS_AMB"));
        ISavingsXDaiAdapter adapter = ISavingsXDaiAdapter(vm.envAddress("SAVINGS_XDAI_ADAPTER"));
        address foreign = vm.envOr("ETHEREUM_XDAI_BRIDGE", ChainConstants.ETHEREUM_XDAI_BRIDGE);
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        vault = new SavingsXDaiSettlementVault(home, amb, adapter, expectedRouter, foreign);
        vm.stopBroadcast();
    }
}
