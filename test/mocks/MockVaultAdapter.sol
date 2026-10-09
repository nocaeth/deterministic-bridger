// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract MockVaultAdapter {
    uint256 public totalValue;
    uint256 public callCount;
    uint256 public ratio = 1;
    address public lastReceiver;
    uint256 public lastValue;
    bool public shouldRevert;
    bool public exhaustGas;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    mapping(address => uint256) public sharesOf;

    function setBehavior(bool fail, bool exhaust, uint256 sharesRatio) external {
        shouldRevert = fail;
        exhaustGas = exhaust;
        ratio = sharesRatio;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function depositXDAI(address receiver) external payable returns (uint256 shares) {
        require(!shouldRevert, "ADAPTER_FAILED");
        if (exhaustGas) assembly { invalid() }
        if (reentryTarget != address(0)) (reentrySucceeded,) = reentryTarget.call(reentryData);
        shares = msg.value * ratio;
        totalValue += msg.value;
        callCount++;
        lastReceiver = receiver;
        lastValue = msg.value;
        sharesOf[receiver] += shares;
    }
}
