// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/fee/BaseDynamicAfterFee.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract BaseDynamicAfterFeeMock is BaseDynamicAfterFee {
    using CurrencySettler for Currency;

    uint256 public targetOutput;
    bool public applyTargetOutput;

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    function getTargetOutput() public view returns (uint256) {
        return _targetOutput;
    }

    function setTargetOutput(uint256 output, bool active) public {
        targetOutput = output;
        applyTargetOutput = active;
    }

    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        uint256,
        uint256 feeAmount
    ) internal override {
        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? (key.currency1) : (key.currency0);

        // Burn ERC-6909 and take underlying tokens
        unspecified.settle(poolManager, address(this), feeAmount, true);
        unspecified.take(poolManager, address(this), feeAmount, false);
    }

    function _getTargetOutput(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (uint256, bool)
    {
        return (targetOutput, applyTargetOutput);
    }

    receive() external payable {}

    // Exclude from coverage report
    function test() public {}
}
