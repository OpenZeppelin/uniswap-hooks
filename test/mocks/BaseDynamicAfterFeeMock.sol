// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/fee/BaseDynamicAfterFee.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/*
 * @dev Mock for BaseDynamicAfterFee.
 * In this mock, `mockTargetOutput` and `mockApplyTargetOutput` allows for easy manipulation
 * of the target output and apply target output to be applied in `_getTargetOutput`.
*/
contract BaseDynamicAfterFeeMock is BaseDynamicAfterFee {
    using CurrencySettler for Currency;

    uint256 private _mockTargetOutput;
    bool private _mockApplyTargetOutput;

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    function setMockTargetOutput(uint256 output, bool active) public {
        _mockTargetOutput = output;
        _mockApplyTargetOutput = active;
    }

    function getMockTargetOutput() public view returns (uint256) {
        return _mockTargetOutput;
    }

    function getMockApplyTargetOutput() public view returns (bool) {
        return _mockApplyTargetOutput;
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
        return (_mockTargetOutput, _mockApplyTargetOutput);
    }

    receive() external payable {}

    // Exclude from coverage report
    function test() public {}
}
