// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script } from "forge-std/Script.sol";
import { GnosisAmbSettlementRouter } from "../src/GnosisAmbSettlementRouter.sol";
import { IHomeXDaiBridge } from "../src/interfaces/IHomeXDaiBridge.sol";
import { IAMB } from "../src/interfaces/IAMB.sol";
import { ISavingsXDaiAdapter } from "../src/interfaces/ISavingsXDaiAdapter.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";

/// @notice Simulates Gnosis router deployment for fork regression tests; never broadcasts.
contract DeployAmbGnosisRouter is Script {
    /// @notice Deploys with the configured canonical bridge, AMB and savings adapter.
    function run() external returns (GnosisAmbSettlementRouter gnosisRouter) {
        require(block.chainid == 100, "GNOSIS_ONLY");
        address expectedRouter = vm.envAddress("EXPECTED_MAINNET_AMB_ROUTER");
        IHomeXDaiBridge home =
            IHomeXDaiBridge(vm.envOr("HOME_XDAI_BRIDGE", ChainConstants.GNOSIS_XDAI_BRIDGE));
        IAMB amb = IAMB(vm.envAddress("GNOSIS_AMB"));
        ISavingsXDaiAdapter adapter = ISavingsXDaiAdapter(vm.envAddress("SAVINGS_XDAI_ADAPTER"));
        address foreign = vm.envOr("ETHEREUM_XDAI_BRIDGE", ChainConstants.ETHEREUM_XDAI_BRIDGE);
        vm.startPrank(vm.addr(vm.envUint("PRIVATE_KEY")));
        gnosisRouter = new GnosisAmbSettlementRouter(home, amb, adapter, expectedRouter, foreign);
        vm.stopPrank();
    }
}
