// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { BridgeClaimLib } from "../libraries/BridgeClaimLib.sol";

/// @notice AMB delivery context and lane configuration used by the claim protocol.
interface IAMB {
    /// @notice Requests delivery of `data` to `target` on the configured destination chain.
    function requireToPassMessage(address target, bytes calldata data, uint256 gasLimit)
        external
        returns (bytes32);
    /// @notice Returns the authenticated sending contract during message delivery.
    function messageSender() external view returns (address);
    /// @notice Returns the authenticated source chain during message delivery.
    function messageSourceChainId() external view returns (uint256);
    /// @notice Returns the current delivery's message identifier.
    function messageId() external view returns (bytes32);
    /// @notice Returns the largest gas limit accepted for one message.
    function maxGasPerTx() external view returns (uint256);
    /// @notice Returns this AMB's configured local chain ID.
    function sourceChainId() external view returns (uint256);
    /// @notice Returns this AMB's configured remote chain ID.
    function destinationChainId() external view returns (uint256);
}

/// @notice Destination handler for immutable source claims.
interface IAMBClaimReceiver {
    /// @notice Registers a claim delivered by the authenticated source router.
    function registerClaim(BridgeClaimLib.Claim calldata claim) external returns (bytes32);
}
