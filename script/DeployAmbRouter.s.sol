// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script } from "forge-std/Script.sol";
import { MainnetAmbBridgeRouter } from "../src/MainnetAmbBridgeRouter.sol";
import { INonceXDaiBridge } from "../src/interfaces/INonceXDaiBridge.sol";
import { IAMB } from "../src/interfaces/IAMB.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";

/// @notice Simulates router deployment for fork regression tests; never broadcasts.
contract DeployAmbRouter is Script {
    /// @notice Validates the expected CREATE nonce and deploys with the configured bridge and AMB.
    function run() external returns (MainnetAmbBridgeRouter router) {
        require(block.chainid == 1, "ETHEREUM_ONLY");
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        uint256 nonce = vm.envUint("EXPECTED_MAINNET_DEPLOYER_NONCE");
        address expectedRouter = vm.envAddress("EXPECTED_MAINNET_AMB_ROUTER");
        require(
            vm.getNonce(deployer) == nonce
                && vm.computeCreateAddress(deployer, nonce) == expectedRouter,
            "DEPLOYER_NONCE_CHANGED"
        );
        address gnosisRouter = vm.envAddress("AMB_GNOSIS_ROUTER");
        address home = vm.envOr("HOME_XDAI_BRIDGE", ChainConstants.GNOSIS_XDAI_BRIDGE);
        INonceXDaiBridge foreign =
            INonceXDaiBridge(vm.envOr("ETHEREUM_XDAI_BRIDGE", ChainConstants.ETHEREUM_XDAI_BRIDGE));
        IAMB amb = IAMB(vm.envAddress("ETHEREUM_AMB"));
        address pauseAuthority = vm.envAddress("MAINNET_PAUSE_AUTHORITY");
        vm.startPrank(deployer);
        router = new MainnetAmbBridgeRouter(foreign, amb, home, gnosisRouter, pauseAuthority);
        vm.stopPrank();
        require(address(router) == expectedRouter, "ROUTER_ADDRESS_MISMATCH");
    }
}
