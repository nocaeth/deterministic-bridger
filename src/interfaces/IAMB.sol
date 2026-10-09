// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { VaultClaimLib } from "../libraries/VaultClaimLib.sol";

interface IAMB {
    function requireToPassMessage(address target, bytes calldata data, uint256 gasLimit)
        external
        returns (bytes32);
    function messageSender() external view returns (address);
    function messageSourceChainId() external view returns (uint256);
    function messageId() external view returns (bytes32);
    function maxGasPerTx() external view returns (uint256);
    function sourceChainId() external view returns (uint256);
    function destinationChainId() external view returns (uint256);
}

interface IAMBClaimReceiver {
    function registerClaim(VaultClaimLib.Claim calldata claim) external returns (bytes32);
}
