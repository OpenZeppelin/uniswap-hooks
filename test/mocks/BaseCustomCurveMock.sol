// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {BaseCustomCurve} from "src/base/BaseCustomCurve.sol";

contract BaseCustomCurveMock is BaseCustomCurve {
    using CurrencySettler for Currency;

    constructor(IPoolManager _manager) BaseCustomCurve(_manager, "Mock", "MOCK") {}

    function _getAmountOutFromExactInput(uint256 amountIn, Currency, Currency, bool)
        internal
        pure
        override
        returns (uint256 amountOut)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountOut = amountIn;
    }

    function _getAmountInForExactOutput(uint256 amountOut, Currency, Currency, bool)
        internal
        pure
        override
        returns (uint256 amountIn)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountIn = amountOut;
    }

    function _calculateIn(AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        liquidity = amount0 + amount1;
    }

    function _calculateOut(RemoveLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        amount0 = liquidity / 2;
        amount1 = liquidity / 2;
        liquidity = amount0 + amount1;
    }

    // Exclude from coverage report
    function test() public {}
}
