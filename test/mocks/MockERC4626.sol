// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC4626 } from "../../src/interfaces/IERC4626.sol";
import { MockERC20 } from "./MockERC20.sol";

contract MockERC4626 is IERC4626 {
    string public name = "Mock sUSDS";
    string public symbol = "sUSDS";
    uint8 public decimals = 18;

    MockERC20 public immutable assetToken;
    uint256 public assetsPerShare = 1;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(MockERC20 assetToken_) {
        assetToken = assetToken_;
    }

    function setAssetsPerShare(uint256 assetsPerShare_) external {
        assetsPerShare = assetsPerShare_;
    }

    function mint(address to, uint256 shares) external {
        balanceOf[to] += shares;
    }

    function approve(address spender, uint256 shares) external returns (bool) {
        allowance[msg.sender][spender] = shares;
        return true;
    }

    function transfer(address to, uint256 shares) external returns (bool) {
        require(balanceOf[msg.sender] >= shares, "BALANCE");

        balanceOf[msg.sender] -= shares;
        balanceOf[to] += shares;
        return true;
    }

    function transferFrom(address from, address to, uint256 shares) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= shares, "ALLOWANCE");
        require(balanceOf[from] >= shares, "BALANCE");

        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - shares;
        }

        balanceOf[from] -= shares;
        balanceOf[to] += shares;
        return true;
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        uint256 allowed = allowance[owner][msg.sender];
        require(allowed >= shares, "ALLOWANCE");
        require(balanceOf[owner] >= shares, "BALANCE");

        if (allowed != type(uint256).max) {
            allowance[owner][msg.sender] = allowed - shares;
        }

        balanceOf[owner] -= shares;
        assets = shares * assetsPerShare;
        assetToken.mint(receiver, assets);
    }
}
