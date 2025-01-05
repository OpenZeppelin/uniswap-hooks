// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BaseCustomCurve} from "src/base/BaseCustomCurve.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract BaseCustomCurveMock is BaseCustomCurve, ERC20 {
    constructor(IPoolManager _manager) BaseCustomCurve(_manager) ERC20("Mock", "MOCK") {}

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

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        pure
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        liquidity = (amount0 + amount1) / 2;
    }

    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        pure
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        amount0 = params.liquidity / 2;
        amount1 = params.liquidity / 2;
        liquidity = params.liquidity;
    }

    function _mint(AddLiquidityParams memory params, BalanceDelta, uint256 liquidity) internal override {
        _mint(params.to, liquidity);
    }

    function _burn(RemoveLiquidityParams memory, BalanceDelta, uint256 liquidity) internal override {
        _burn(msg.sender, liquidity);
    }

    // Exclude from coverage report
    function test() public {}
}
