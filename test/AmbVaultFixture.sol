// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { MainnetAmbBridgeRouter } from "../src/MainnetAmbBridgeRouter.sol";
import { SavingsXDaiSettlementVault } from "../src/SavingsXDaiSettlementVault.sol";
import { IAMB, IAMBClaimReceiver } from "../src/interfaces/IAMB.sol";
import { IHomeXDaiBridge } from "../src/interfaces/IHomeXDaiBridge.sol";
import { INonceXDaiBridge } from "../src/interfaces/INonceXDaiBridge.sol";
import { ISavingsXDaiAdapter } from "../src/interfaces/ISavingsXDaiAdapter.sol";
import { IERC20 } from "../src/interfaces/IERC20.sol";
import { ChainConstants } from "../src/libraries/ChainConstants.sol";
import { VaultClaimLib } from "../src/libraries/VaultClaimLib.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC4626 } from "./mocks/MockERC4626.sol";
import { MockNonceXDaiBridge } from "./mocks/MockNonceXDaiBridge.sol";
import { MockHomeXDaiBridge } from "./mocks/MockHomeXDaiBridge.sol";
import { MockAMB } from "./mocks/MockAMB.sol";
import { MockVaultAdapter } from "./mocks/MockVaultAdapter.sol";

abstract contract AmbVaultFixture is Test {
    MainnetAmbBridgeRouter internal router;
    SavingsXDaiSettlementVault internal vault;
    MockERC20 internal usds;
    MockERC4626 internal susds;
    MockNonceXDaiBridge internal foreign;
    MockHomeXDaiBridge internal home;
    MockAMB internal amb;
    MockAMB internal sourceAMB;
    MockVaultAdapter internal adapter;
    address internal payer = address(0xB0B);
    address internal recipient = address(0xA11CE);

    function setUp() public virtual {
        vm.etch(ChainConstants.ETHEREUM_USDS, address(new MockERC20()).code);
        usds = MockERC20(ChainConstants.ETHEREUM_USDS);
        vm.etch(ChainConstants.ETHEREUM_SUSDS, address(new MockERC4626(usds)).code);
        susds = MockERC4626(ChainConstants.ETHEREUM_SUSDS);
        susds.setAssetsPerShare(1);
        foreign = new MockNonceXDaiBridge(IERC20(address(usds)));
        home = new MockHomeXDaiBridge();
        amb = new MockAMB(100, 1);
        sourceAMB = new MockAMB(1, 100);
        adapter = new MockVaultAdapter();
        address expectedRouter =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vm.chainId(100);
        vault = new SavingsXDaiSettlementVault(
            IHomeXDaiBridge(address(home)),
            IAMB(address(amb)),
            ISavingsXDaiAdapter(address(adapter)),
            expectedRouter,
            address(foreign)
        );
        vm.chainId(1);
        router = new MainnetAmbBridgeRouter(
            INonceXDaiBridge(address(foreign)),
            IAMB(address(sourceAMB)),
            address(home),
            address(vault)
        );
        assertEq(address(router), expectedRouter);
    }

    function _bridgeUSDS(uint256 amount, uint256 minimum) internal returns (bytes32 id) {
        vm.chainId(1);
        usds.mint(payer, amount);
        vm.prank(payer);
        usds.approve(address(router), amount);
        vm.prank(payer);
        (id,) = router.bridgeTo(recipient, amount, minimum);
    }

    function _bridgeSavings(uint256 shares, uint256 minimum) internal returns (bytes32 id) {
        vm.chainId(1);
        susds.mint(payer, shares);
        vm.prank(payer);
        susds.approve(address(router), shares);
        vm.prank(payer);
        (id,) = router.bridgeSavingsUSDSTo(recipient, shares, minimum);
    }

    function _deliver(bytes32 id) internal returns (bool success) {
        return _deliverClaim(router.getClaim(id), address(router), 1, 700_000);
    }

    function _deliverClaim(
        VaultClaimLib.Claim memory c,
        address sender,
        uint256 chain,
        uint256 gasLimit
    ) internal returns (bool success) {
        vm.chainId(100);
        (success,) = amb.deliver(
            address(vault),
            sender,
            chain,
            abi.encodeCall(IAMBClaimReceiver.registerClaim, (c)),
            gasLimit
        );
    }

    function _execute(bytes32 id) internal {
        vm.chainId(100);
        VaultClaimLib.Claim memory c = router.getClaim(id);
        home.setProcessed(
            keccak256(abi.encodePacked(address(vault), c.amount, c.bridgeNonce)), true
        );
    }

    function _credit(uint256 amount) internal {
        vm.chainId(100);
        vm.deal(address(vault), address(vault).balance + amount);
    }
}
