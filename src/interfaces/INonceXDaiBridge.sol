// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IXDaiBridge } from "./IXDaiBridge.sol";

interface INonceXDaiBridge is IXDaiBridge {
    function nonce() external view returns (uint256);
    function erc20token() external view returns (address);
    function implementation() external view returns (address);
}
