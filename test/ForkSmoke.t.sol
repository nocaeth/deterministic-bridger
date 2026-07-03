// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";
import { IXDaiBridge } from "../src/interfaces/IXDaiBridge.sol";

/// @notice Minimal proxy interface for the Ethereum xDai bridge smoke check.
interface IBridgeProxy {
    /// @notice Returns the current bridge implementation.
    /// @return implementation Current implementation address.
    function implementation() external view returns (address);
}

contract ForkSmokeTest is Test {
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
}
