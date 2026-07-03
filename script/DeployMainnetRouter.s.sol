// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script } from "forge-std/Script.sol";
import { MainnetStablecoinBridgeRouter } from "../src/MainnetStablecoinBridgeRouter.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IXDaiBridge } from "../src/interfaces/IXDaiBridge.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";

/// @notice Deploys the mainnet stablecoin bridge router.
contract DeployMainnetRouter is Script {
    /// @notice Deploys `MainnetStablecoinBridgeRouter` from environment configuration.
    /// @return router Deployed mainnet router.
    function run() external returns (MainnetStablecoinBridgeRouter router) {
        IERC20 mainnetToken = IERC20(vm.envAddress("MAINNET_TOKEN"));
        IXDaiBridge foreignBridge =
            IXDaiBridge(vm.envOr("ETHEREUM_XDAI_BRIDGE", ChainConstants.ETHEREUM_XDAI_BRIDGE));
        address gnosisFactory = vm.envAddress("SAVINGS_XDAI_RECEIVER_FACTORY");
        address gnosisSingleton = vm.envAddress("GNOSIS_SINGLETON");

        vm.startBroadcast();
        router = new MainnetStablecoinBridgeRouter(
            mainnetToken, foreignBridge, gnosisFactory, gnosisSingleton
        );
        vm.stopBroadcast();
    }
}
