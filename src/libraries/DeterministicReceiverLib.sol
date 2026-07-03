// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title DeterministicReceiverLib
/// @notice Computes and deploys deterministic EIP-1167 receivers for deterministic receivers.
/// @dev The receiver address invariant is `CREATE2(factory, salt(deterministicReceiver), clone(singleton))`.
library DeterministicReceiverLib {
    /// @notice Reverts when deterministic clone deployment fails.
    error DeterministicDeployFailed();

    /// @notice Returns the CREATE2 salt derived from a deterministic receiver.
    /// @param deterministicReceiver Address that owns the eventual sDAI shares.
    /// @return receiverSalt Salt used for deterministic receiver deployment.
    function salt(address deterministicReceiver) internal pure returns (bytes32 receiverSalt) {
        receiverSalt = keccak256(abi.encode(deterministicReceiver));
    }

    /// @notice Returns the EIP-1167 clone creation code for a singleton implementation.
    /// @param singleton Savings xDAI receiver implementation to delegate to.
    /// @return code Minimal proxy creation code.
    function cloneCreationCode(address singleton) internal pure returns (bytes memory code) {
        code = abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            bytes20(singleton),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
    }

    /// @notice Returns the hash of the EIP-1167 clone creation code.
    /// @param singleton Savings xDAI receiver implementation to delegate to.
    /// @return codeHash Keccak hash used in CREATE2 address prediction.
    function creationCodeHash(address singleton) internal pure returns (bytes32 codeHash) {
        codeHash = keccak256(cloneCreationCode(singleton));
    }

    /// @notice Predicts the deterministic receiver for a deterministic receiver.
    /// @param factory Gnosis factory that deploys the clone.
    /// @param singleton Savings xDAI receiver implementation used by the clone.
    /// @param deterministicReceiver Address that owns the eventual sDAI shares.
    /// @return predicted Deterministic Gnosis receiver address.
    function predict(address factory, address singleton, address deterministicReceiver)
        internal
        pure
        returns (address predicted)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                bytes1(0xff), factory, salt(deterministicReceiver), creationCodeHash(singleton)
            )
        );
        predicted = address(uint160(uint256(digest)));
    }

    /// @notice Deploys the deterministic EIP-1167 receiver clone.
    /// @param singleton Savings xDAI receiver implementation used by the clone.
    /// @param deterministicReceiver Address used only for salt derivation.
    /// @return receiver Deployed deterministic Gnosis receiver address.
    function deploy(address singleton, address deterministicReceiver)
        internal
        returns (address receiver)
    {
        bytes32 receiverSalt = salt(deterministicReceiver);
        bytes memory code = cloneCreationCode(singleton);

        assembly {
            receiver := create2(0, add(code, 0x20), mload(code), receiverSalt)
        }

        if (receiver == address(0)) revert DeterministicDeployFailed();
    }
}
