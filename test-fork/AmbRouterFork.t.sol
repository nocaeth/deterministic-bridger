// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IERC4626 } from "../src/interfaces/IERC4626.sol";
import { INonceXDaiBridge } from "../src/interfaces/INonceXDaiBridge.sol";
import { IHomeXDaiBridge } from "../src/interfaces/IHomeXDaiBridge.sol";
import { IAMB, IAMBClaimReceiver } from "../src/interfaces/IAMB.sol";
import { ISavingsXDaiAdapter } from "../src/interfaces/ISavingsXDaiAdapter.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";
import { BridgeClaimLib } from "../src/libraries/BridgeClaimLib.sol";
import { GnosisAmbSettlementRouter as Vault } from "../src/GnosisAmbSettlementRouter.sol";
import { MockAMB } from "../test/mocks/MockAMB.sol";
import { DeployAmbGnosisRouter } from "../script/DeployAmbGnosisRouter.s.sol";
import { DeployAmbRouter } from "../script/DeployAmbRouter.s.sol";
import { MainnetAmbBridgeRouter } from "../src/MainnetAmbBridgeRouter.sol";
import { EthereumBridgeReturnReceiver } from "../src/EthereumBridgeReturnReceiver.sol";

contract AmbRouterForkTest is Test {
    address internal constant FOREIGN_AMB = 0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e;
    address internal constant HOME_AMB = 0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59;
    address internal constant ADAPTER = 0xD499b51fcFc66bd31248ef4b28d656d67E591A94;

    function testPinnedEthereumRelayNonceAndActualFunding() external {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 26_154_748);
        assertEq(block.chainid, 1);
        INonceXDaiBridge bridge = INonceXDaiBridge(ChainConstants.ETHEREUM_XDAI_BRIDGE);
        assertEq(bridge.erc20token(), ChainConstants.ETHEREUM_USDS);
        assertGt(bridge.implementation().code.length, 0);
        assertEq(IERC4626(ChainConstants.ETHEREUM_SUSDS).asset(), ChainConstants.ETHEREUM_USDS);
        assertEq(IAMB(FOREIGN_AMB).sourceChainId(), 1);
        assertEq(IAMB(FOREIGN_AMB).destinationChainId(), 100);
        assertGe(IAMB(FOREIGN_AMB).maxGasPerTx(), 700_000);
        IERC20 token = IERC20(ChainConstants.ETHEREUM_USDS);
        deal(address(token), address(this), 5 ether);
        token.approve(address(bridge), 5 ether);
        uint256 nonce = bridge.nonce();
        uint256 beforeBalance = token.balanceOf(address(bridge));
        address destination = address(0xA11CE);
        vm.recordLogs();
        bridge.relayTokens(destination, 5 ether);
        assertEq(bridge.nonce(), nonce + 1);
        assertEq(token.balanceOf(address(bridge)), beforeBalance + 5 ether);
        assertEq(token.balanceOf(address(this)), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool matched;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(bridge)
                    || logs[i].topics[0]
                        != keccak256("UserRequestForAffirmation(address,uint256,bytes32)")
            ) continue;
            (address recipient, uint256 amount, bytes32 actualNonce) =
                abi.decode(logs[i].data, (address, uint256, bytes32));
            matched = recipient == destination && amount == 5 ether && actualNonce == bytes32(nonce);
        }
        assertTrue(matched, "relay event must carry captured nonce and amount");
    }

    function testPinnedGnosisExecutionAndRealAdapterGas() external {
        vm.createSelectFork(vm.envString("GNOSIS_RPC_URL"), 48_668_463);
        assertEq(block.chainid, 100);
        IHomeXDaiBridge home = IHomeXDaiBridge(ChainConstants.GNOSIS_XDAI_BRIDGE);
        assertEq(home.feeManagerContract(), address(0));
        assertEq(home.decimalShift(), 0);
        bytes32 hash = keccak256(
            abi.encodePacked(
                address(0x455F7c393a7cA1e05E402B06892527383688E7DE),
                uint256(5 ether),
                bytes32(uint256(0x1c35))
            )
        );
        assertTrue(home.isAlreadyProcessed(home.numAffirmationsSigned(hash)));
        assertFalse(
            home.isAlreadyProcessed(home.numAffirmationsSigned(keccak256("unexecuted claim")))
        );
        assertEq(IAMB(HOME_AMB).sourceChainId(), 100);
        assertEq(IAMB(HOME_AMB).destinationChainId(), 1);
        assertGe(IAMB(HOME_AMB).maxGasPerTx(), 700_000);
        address recipient = address(0xA11CE);
        uint256 beforeShares = IERC20(ChainConstants.GNOSIS_SDAI).balanceOf(recipient);
        vm.deal(address(this), 5 ether);
        uint256 gasBefore = gasleft();
        uint256 shares = ISavingsXDaiAdapter(ADAPTER).depositXDAI{ value: 5 ether }(recipient);
        uint256 used = gasBefore - gasleft();
        assertGt(shares, 0);
        assertEq(IERC20(ChainConstants.GNOSIS_SDAI).balanceOf(recipient) - beforeShares, shares);
        assertLt(used, 250_000, "adapter must leave room inside 350k settlement budget");
        emit log_named_uint("real_adapter_gas", used);
    }

    function testCallbackBudgetWithRealAdapterAndSimulatedExecutionMarker() external {
        vm.createSelectFork(vm.envString("GNOSIS_RPC_URL"), 48_668_463);
        IHomeXDaiBridge home = IHomeXDaiBridge(ChainConstants.GNOSIS_XDAI_BRIDGE);
        MockAMB amb = new MockAMB(100, 1);
        address source = address(0x1234);
        Vault vault = new Vault(
            home,
            IAMB(address(amb)),
            ISavingsXDaiAdapter(ADAPTER),
            source,
            ChainConstants.ETHEREUM_XDAI_BRIDGE
        );
        vm.deal(address(vault), 20 ether);
        BridgeClaimLib.Claim memory c = BridgeClaimLib.Claim(
            bytes32(uint256(9000)), address(this), address(0xA11CE), 5 ether, 1
        );
        bytes32 transferHash = keccak256(abi.encodePacked(address(vault), c.amount, c.bridgeNonce));
        // Only the execution marker is simulated; configuration and savings conversion use real contracts.
        vm.mockCall(
            address(home),
            abi.encodeCall(home.numAffirmationsSigned, (transferHash)),
            abi.encode(uint256(1 << 255))
        );
        uint256 beforeGas = gasleft();
        (bool success, bytes memory result) = amb.deliver(
            address(vault), source, 1, abi.encodeCall(IAMBClaimReceiver.registerClaim, (c)), 700_000
        );
        uint256 used = beforeGas - gasleft();
        assertTrue(success);
        bytes32 id = abi.decode(result, (bytes32));
        assertEq(uint256(vault.settlementStatus(id)), uint256(Vault.SettlementResult.Paid));
        assertLt(used, 600_000);
        emit log_named_uint("ready_callback_with_mock_AMB_gas", used);
        beforeGas = gasleft();
        (success,) = amb.deliver(
            address(vault), source, 1, abi.encodeCall(IAMBClaimReceiver.registerClaim, (c)), 700_000
        );
        assertTrue(success);
        emit log_named_uint("paid_duplicate_callback_with_mock_AMB_gas", beforeGas - gasleft());

        c.bridgeNonce = bytes32(uint256(9001));
        c.minShares = type(uint256).max;
        transferHash = keccak256(abi.encodePacked(address(vault), c.amount, c.bridgeNonce));
        vm.mockCall(
            address(home),
            abi.encodeCall(home.numAffirmationsSigned, (transferHash)),
            abi.encode(uint256(1 << 255))
        );
        beforeGas = gasleft();
        (success, result) = amb.deliver(
            address(vault), source, 1, abi.encodeCall(IAMBClaimReceiver.registerClaim, (c)), 700_000
        );
        assertTrue(success);
        id = abi.decode(result, (bytes32));
        (, Vault.ClaimStatus status,) = vault.getClaim(id);
        assertEq(uint256(status), uint256(Vault.ClaimStatus.Pending));
        assertEq(address(vault).balance, 15 ether);
        emit log_named_uint("failed_minimum_callback_with_mock_AMB_gas", beforeGas - gasleft());
    }

    function testMirroredRecoveryAndSimulationScriptsRejectChangedNonce() external {
        uint256 mainnet = vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 26_154_748);
        uint256 routerKey = 0x123456;
        uint256 vaultKey = 0xA11CEB0B20261009;
        address routerDeployer = vm.addr(routerKey);
        address vaultDeployer = vm.addr(vaultKey);
        uint256 routerNonce = vm.getNonce(routerDeployer);
        uint256 vaultNonce = vm.getNonce(vaultDeployer);
        address expectedRouter = vm.computeCreateAddress(routerDeployer, routerNonce);
        address expectedVault = vm.computeCreateAddress(vaultDeployer, vaultNonce);
        vm.startPrank(vaultDeployer);
        EthereumBridgeReturnReceiver receiver = new EthereumBridgeReturnReceiver(routerDeployer);
        vm.stopPrank();
        assertEq(address(receiver), expectedVault);
        vm.setEnv("EXPECTED_MAINNET_DEPLOYER_NONCE", vm.toString(routerNonce));
        vm.setEnv("EXPECTED_MAINNET_AMB_ROUTER", vm.toString(expectedRouter));
        vm.setEnv("MAINNET_PAUSE_AUTHORITY", vm.toString(routerDeployer));
        vm.setEnv("GNOSIS_AMB", vm.toString(HOME_AMB));
        vm.setEnv("ETHEREUM_AMB", vm.toString(FOREIGN_AMB));
        vm.setEnv("SAVINGS_XDAI_ADAPTER", vm.toString(ADAPTER));
        vm.setEnv("HOME_XDAI_BRIDGE", vm.toString(ChainConstants.GNOSIS_XDAI_BRIDGE));
        vm.setEnv("ETHEREUM_XDAI_BRIDGE", vm.toString(ChainConstants.ETHEREUM_XDAI_BRIDGE));
        vm.createSelectFork(vm.envString("GNOSIS_RPC_URL"), 48_668_463);
        assertEq(vm.getNonce(vaultDeployer), vaultNonce);
        vm.setEnv("PRIVATE_KEY", vm.toString(vaultKey));
        Vault vault = (new DeployAmbGnosisRouter()).run();
        assertEq(address(vault), expectedVault);
        assertEq(vault.sourceRouter(), expectedRouter);
        vm.setEnv("AMB_GNOSIS_ROUTER", vm.toString(address(vault)));
        vm.selectFork(mainnet);
        vm.setEnv("PRIVATE_KEY", vm.toString(routerKey));
        DeployAmbRouter script = new DeployAmbRouter();
        vm.setEnv("EXPECTED_MAINNET_DEPLOYER_NONCE", vm.toString(routerNonce + 1));
        vm.expectRevert("DEPLOYER_NONCE_CHANGED");
        script.run();
        vm.setEnv("EXPECTED_MAINNET_DEPLOYER_NONCE", vm.toString(routerNonce));
        MainnetAmbBridgeRouter router = script.run();
        assertEq(address(router), expectedRouter);
        assertEq(router.gnosisRouter(), address(vault));
        assertEq(router.pauseAuthority(), routerDeployer);
        assertEq(receiver.recoveryAuthority(), routerDeployer);
    }
}
