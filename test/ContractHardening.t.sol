// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { AmbRouterFixture } from "./AmbRouterFixture.sol";
import { MainnetAmbBridgeRouter } from "../src/MainnetAmbBridgeRouter.sol";
import { GnosisAmbSettlementRouter } from "../src/GnosisAmbSettlementRouter.sol";
import { IAMB } from "../src/interfaces/IAMB.sol";
import { IHomeXDaiBridge } from "../src/interfaces/IHomeXDaiBridge.sol";
import { INonceXDaiBridge } from "../src/interfaces/INonceXDaiBridge.sol";
import { ISavingsXDaiAdapter } from "../src/interfaces/ISavingsXDaiAdapter.sol";

contract ContractHardeningTest is AmbRouterFixture {
    function testConstructorRejectsSavingsUnderlyingMismatch() external {
        vm.mockCall(address(susds), abi.encodeWithSignature("asset()"), abi.encode(recipient));
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidConfig.selector);
        _deployRouter();
    }

    function testConstructorsRejectWrongLocalChain() external {
        vm.chainId(100);
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidConfig.selector);
        _deployRouter();
        vm.chainId(1);
        vm.expectRevert(GnosisAmbSettlementRouter.InvalidConfig.selector);
        _deployVault();
    }

    function testRouterRequiresBridgeImplementationGetterButVaultDoesNot() external {
        vm.mockCallRevert(address(foreign), abi.encodeWithSignature("implementation()"), "");
        vm.expectRevert();
        _deployRouter();
        vm.clearMockedCalls();
        vm.chainId(100);
        vm.mockCallRevert(address(home), abi.encodeWithSignature("implementation()"), "");
        _deployVault();
    }

    function testRouterRejectsUnsupportedDependencies() external {
        _rejectRouterGetter(address(foreign), "erc20token()", abi.encode(recipient));
        _rejectRouterGetter(address(sourceAMB), "sourceChainId()", abi.encode(uint256(100)));
        _rejectRouterGetter(address(sourceAMB), "destinationChainId()", abi.encode(uint256(1)));
        _rejectRouterGetter(address(sourceAMB), "maxGasPerTx()", abi.encode(uint256(699_999)));
        _rejectRouterGetter(address(foreign), "implementation()", abi.encode(address(0)));
    }

    function testRouterRequiresLocalContractCode() external {
        _rejectRouterCode(address(foreign));
        _rejectRouterCode(address(sourceAMB));
        _rejectRouterCode(address(usds));
        _rejectRouterCode(address(susds));
    }

    function testRouterRejectsMissingRemoteAddresses() external {
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidConfig.selector);
        new MainnetAmbBridgeRouter(
            INonceXDaiBridge(address(foreign)),
            IAMB(address(sourceAMB)),
            address(0),
            address(vault),
            address(this)
        );
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidConfig.selector);
        new MainnetAmbBridgeRouter(
            INonceXDaiBridge(address(foreign)),
            IAMB(address(sourceAMB)),
            address(home),
            address(0),
            address(this)
        );
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidConfig.selector);
        new MainnetAmbBridgeRouter(
            INonceXDaiBridge(address(foreign)),
            IAMB(address(sourceAMB)),
            address(home),
            address(vault),
            address(0)
        );
    }

    function testVaultRejectsUnsupportedDependencies() external {
        vm.chainId(100);
        _rejectVaultGetter(address(home), "feeManagerContract()", abi.encode(recipient));
        _rejectVaultGetter(address(home), "decimalShift()", abi.encode(int256(1)));
        _rejectVaultGetter(address(home), "decimalShift()", abi.encode(int256(-1)));
        _rejectVaultGetter(address(amb), "sourceChainId()", abi.encode(uint256(1)));
        _rejectVaultGetter(address(amb), "destinationChainId()", abi.encode(uint256(100)));
    }

    function testVaultRequiresLocalContractCode() external {
        vm.chainId(100);
        _rejectVaultCode(address(home));
        _rejectVaultCode(address(amb));
        _rejectVaultCode(address(adapter));
    }

    function testVaultRejectsMissingRemoteAddresses() external {
        vm.chainId(100);
        vm.expectRevert(GnosisAmbSettlementRouter.InvalidConfig.selector);
        new GnosisAmbSettlementRouter(
            IHomeXDaiBridge(address(home)),
            IAMB(address(amb)),
            ISavingsXDaiAdapter(address(adapter)),
            address(0),
            address(foreign)
        );
        vm.expectRevert(GnosisAmbSettlementRouter.InvalidConfig.selector);
        new GnosisAmbSettlementRouter(
            IHomeXDaiBridge(address(home)),
            IAMB(address(amb)),
            ISavingsXDaiAdapter(address(adapter)),
            address(router),
            address(0)
        );
    }

    function _deployRouter() private returns (MainnetAmbBridgeRouter) {
        return new MainnetAmbBridgeRouter(
            INonceXDaiBridge(address(foreign)),
            IAMB(address(sourceAMB)),
            address(home),
            address(vault),
            address(this)
        );
    }

    function _deployVault() private returns (GnosisAmbSettlementRouter) {
        return new GnosisAmbSettlementRouter(
            IHomeXDaiBridge(address(home)),
            IAMB(address(amb)),
            ISavingsXDaiAdapter(address(adapter)),
            address(router),
            address(foreign)
        );
    }

    function _rejectRouterGetter(address target, string memory signature, bytes memory result)
        private
    {
        vm.mockCall(target, abi.encodeWithSignature(signature), result);
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidConfig.selector);
        _deployRouter();
        vm.clearMockedCalls();
    }

    function _rejectVaultGetter(address target, string memory signature, bytes memory result)
        private
    {
        vm.mockCall(target, abi.encodeWithSignature(signature), result);
        vm.expectRevert(GnosisAmbSettlementRouter.InvalidConfig.selector);
        _deployVault();
        vm.clearMockedCalls();
    }

    function _rejectRouterCode(address target) private {
        bytes memory code = target.code;
        vm.etch(target, "");
        vm.expectRevert(MainnetAmbBridgeRouter.InvalidConfig.selector);
        _deployRouter();
        vm.etch(target, code);
    }

    function _rejectVaultCode(address target) private {
        bytes memory code = target.code;
        vm.etch(target, "");
        vm.expectRevert(GnosisAmbSettlementRouter.InvalidConfig.selector);
        _deployVault();
        vm.etch(target, code);
    }
}
