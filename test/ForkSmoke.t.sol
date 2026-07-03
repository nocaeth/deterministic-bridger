// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { IXDaiBridge } from "../src/interfaces/IXDaiBridge.sol";
import { MainnetStablecoinBridgeRouter } from "../src/MainnetStablecoinBridgeRouter.sol";

/// @notice Minimal proxy interface for the Ethereum xDai bridge smoke check.
interface IBridgeProxy {
    /// @notice Returns the current bridge implementation.
    /// @return implementation Current implementation address.
    function implementation() external view returns (address);
}

/// @notice Minimal token getter exposed by the Ethereum xDai bridge implementation.
interface IBridgeToken {
    /// @notice Returns the ERC-20 token pulled by `relayTokens`.
    /// @return token Current Ethereum token accepted by the bridge.
    function erc20token() external view returns (address token);
}

/// @notice Minimal factory interface for cross-chain prediction smoke checks.
interface IReceiverFactory {
    /// @notice Predicts the Gnosis receiver for a deterministic receiver.
    /// @param deterministicReceiver Address used as the CREATE2 salt input.
    /// @return receiver Deterministic Gnosis receiver.
    function predict(address deterministicReceiver) external view returns (address receiver);
}

contract ForkSmokeTest is Test {
    bytes32 private constant BRIDGE_REQUESTED_TOPIC =
        keccak256("BridgeRequested(address,address,address,uint256)");
    bytes32 private constant USER_REQUEST_FOR_AFFIRMATION_TOPIC_LEGACY =
        keccak256("UserRequestForAffirmation(address,uint256)");
    bytes32 private constant USER_REQUEST_FOR_AFFIRMATION_TOPIC =
        keccak256("UserRequestForAffirmation(address,uint256,bytes32)");

    function testEthereumXDaiBridgeCodeExistsWhenRpcConfigured() external {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (!_isConfiguredRpc(rpc)) return;

        vm.createSelectFork(rpc);

        assertTrue(
            ChainConstants.ETHEREUM_XDAI_BRIDGE.code.length != 0, "ethereum bridge should have code"
        );

        address implementation = IBridgeProxy(ChainConstants.ETHEREUM_XDAI_BRIDGE).implementation();
        assertTrue(
            implementation.code.length != 0, "ethereum bridge implementation should have code"
        );
        assertTrue(
            _containsSelector(implementation.code, IXDaiBridge.relayTokens.selector),
            "ethereum bridge implementation should expose relayTokens(address,uint256)"
        );
    }

    function testGnosisConfiguredContractsHaveCodeWhenRpcConfigured() external {
        string memory rpc = vm.envOr("GNOSIS_RPC_URL", string(""));
        if (!_isConfiguredRpc(rpc)) return;

        vm.createSelectFork(rpc);

        assertTrue(
            ChainConstants.GNOSIS_XDAI_BRIDGE.code.length != 0, "gnosis bridge should have code"
        );
        assertTrue(ChainConstants.GNOSIS_SDAI.code.length != 0, "sdai should have code");

        address helper = vm.envOr("SAVINGS_XDAI_ADAPTER", address(0));
        if (helper != address(0)) {
            assertTrue(helper.code.length != 0, "savings helper should have code");
        }
    }

    function testMainnetRouterEmitsBridgeInitiationEventWhenRpcConfigured() external {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        address routerAddress = vm.envOr("ROUTER", address(0));
        if (!_isConfiguredRpc(rpc) || routerAddress == address(0)) {
            return;
        }

        uint256 mainnetFork = vm.createSelectFork(rpc);

        MainnetStablecoinBridgeRouter router = MainnetStablecoinBridgeRouter(routerAddress);
        address bridgeToken = IBridgeToken(address(router.foreignBridge())).erc20token();
        assertEq(
            address(router.mainnetToken()),
            bridgeToken,
            "router token must match ethereum xDai bridge token"
        );
        assertEq(
            address(router.savingsUSDS()),
            ChainConstants.ETHEREUM_SUSDS,
            "router should expose Ethereum sUSDS"
        );
        assertTrue(ChainConstants.ETHEREUM_USDS.code.length != 0, "USDS should have code");
        assertTrue(ChainConstants.ETHEREUM_SUSDS.code.length != 0, "sUSDS should have code");

        address mainnetToken = address(router.mainnetToken());
        address deterministicReceiver = makeAddr("deterministicReceiver");
        address gnosisReceiver = router.receiverFor(deterministicReceiver);
        assertEq(
            gnosisReceiver,
            _predictOnGnosisIfConfigured(router, deterministicReceiver),
            "router receiver must match Gnosis CREATE2 prediction"
        );
        vm.selectFork(mainnetFork);

        address payer = makeAddr("payer");
        uint256 amount = 1e18;

        deal(mainnetToken, payer, amount);

        vm.startPrank(payer);
        IERC20(mainnetToken).approve(routerAddress, amount);

        vm.recordLogs();
        router.bridgeTo(deterministicReceiver, amount);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        vm.stopPrank();

        assertTrue(
            _containsRouterBridgeRequestedEvent(
                entries, routerAddress, payer, deterministicReceiver, gnosisReceiver, amount
            ),
            "router should emit BridgeRequested for intended receiver and predicted receiver"
        );
        assertTrue(
            _containsBridgeInitiationEvent(entries, gnosisReceiver, amount),
            "ethereum xDai bridge should emit UserRequestForAffirmation for predicted receiver"
        );
    }

    function _containsSelector(bytes memory code, bytes4 selector) private pure returns (bool) {
        if (code.length < 4) return false;

        for (uint256 i; i <= code.length - 4; i++) {
            bytes4 candidate = bytes4(code[i]) | (bytes4(code[i + 1]) >> 8)
                | (bytes4(code[i + 2]) >> 16) | (bytes4(code[i + 3]) >> 24);
            if (candidate == selector) return true;
        }

        return false;
    }

    function _isConfiguredRpc(string memory rpc) private pure returns (bool) {
        bytes memory value = bytes(rpc);
        if (value.length == 0) return false;

        for (uint256 i; i < value.length; i++) {
            if (value[i] == "<" || value[i] == ">") return false;
        }

        return true;
    }

    function _containsBridgeInitiationEvent(
        Vm.Log[] memory entries,
        address gnosisReceiver,
        uint256 amount
    ) private pure returns (bool) {
        for (uint256 i; i < entries.length; i++) {
            Vm.Log memory entry = entries[i];
            if (entry.emitter != ChainConstants.ETHEREUM_XDAI_BRIDGE) continue;
            if (entry.topics.length == 0) continue;
            if (entry.topics[0] == USER_REQUEST_FOR_AFFIRMATION_TOPIC) {
                (address receiver, uint256 bridgedAmount,) =
                    abi.decode(entry.data, (address, uint256, bytes32));
                if (receiver != gnosisReceiver || bridgedAmount != amount) continue;
                return true;
            }
            if (entry.topics[0] == USER_REQUEST_FOR_AFFIRMATION_TOPIC_LEGACY) {
                if (keccak256(entry.data) != keccak256(abi.encode(gnosisReceiver, amount))) {
                    continue;
                }
                return true;
            }
        }

        return false;
    }

    function _containsRouterBridgeRequestedEvent(
        Vm.Log[] memory entries,
        address router,
        address payer,
        address deterministicReceiver,
        address gnosisReceiver,
        uint256 amount
    ) private pure returns (bool) {
        for (uint256 i; i < entries.length; i++) {
            Vm.Log memory entry = entries[i];
            if (entry.emitter != router) continue;
            if (entry.topics.length != 4) continue;
            if (entry.topics[0] != BRIDGE_REQUESTED_TOPIC) continue;
            if (address(uint160(uint256(entry.topics[1]))) != payer) continue;
            if (address(uint160(uint256(entry.topics[2]))) != deterministicReceiver) continue;
            if (address(uint160(uint256(entry.topics[3]))) != gnosisReceiver) continue;
            if (abi.decode(entry.data, (uint256)) != amount) continue;
            return true;
        }

        return false;
    }

    function _predictOnGnosisIfConfigured(
        MainnetStablecoinBridgeRouter router,
        address deterministicReceiver
    ) private returns (address predicted) {
        predicted = router.receiverFor(deterministicReceiver);

        string memory gnosisRpc = vm.envOr("GNOSIS_RPC_URL", string(""));
        if (!_isConfiguredRpc(gnosisRpc)) return predicted;

        address factory = router.gnosisFactory();
        vm.createSelectFork(gnosisRpc);

        assertTrue(factory.code.length != 0, "Gnosis factory should have code");
        predicted = IReceiverFactory(factory).predict(deterministicReceiver);
    }
}
