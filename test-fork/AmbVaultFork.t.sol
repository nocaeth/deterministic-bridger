// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { INonceXDaiBridge } from "../src/interfaces/INonceXDaiBridge.sol";
import { IHomeXDaiBridge } from "../src/interfaces/IHomeXDaiBridge.sol";
import { IAMB } from "../src/interfaces/IAMB.sol";
import { ISavingsXDaiAdapter } from "../src/interfaces/ISavingsXDaiAdapter.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";

interface IAssetVault {
    function asset() external view returns (address);
}

contract AmbVaultForkTest is Test {
    address internal constant FOREIGN_AMB = 0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e;
    address internal constant HOME_AMB = 0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59;
    address internal constant ADAPTER = 0xD499b51fcFc66bd31248ef4b28d656d67E591A94;

    function testPinnedEthereumRelayNonceAndActualFunding() external {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 26_154_748);
        assertEq(block.chainid, 1);
        INonceXDaiBridge bridge = INonceXDaiBridge(ChainConstants.ETHEREUM_XDAI_BRIDGE);
        assertEq(
            bridge.implementation().codehash,
            0x264cadfbd942c81527ab9bd8494c60509fb89f95cd8dd1ebc0fec72fd64809cb
        );
        assertEq(bridge.erc20token(), ChainConstants.ETHEREUM_USDS);
        assertEq(IAssetVault(ChainConstants.ETHEREUM_SUSDS).asset(), ChainConstants.ETHEREUM_USDS);
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
        assertEq(
            home.implementation().codehash,
            0xfa047c93c784231e57196bf818ec20b303dd1e9a65e4452507361858f7784ab5
        );
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
}
