// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
// Internal imports
import {CurrencySettler} from "../../utils/CurrencySettler.sol";
import {BaseCustomAccountingMock} from "./BaseCustomAccountingMock.sol";

contract BaseCustomAccountingSharedPositionMock is BaseCustomAccountingMock {
    using CurrencySettler for Currency;

    error InvalidTickRange();

    constructor(IPoolManager _poolManager) BaseCustomAccountingMock(_poolManager) {}

    // A shared position must have a single range, so shares minted in one range cannot redeem another
    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        view
        override
        returns (bytes memory, uint256)
    {
        _checkFullRange(params.tickLower, params.tickUpper);
        return super._getAddLiquidity(sqrtPriceX96, params);
    }

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        view
        override
        returns (bytes memory, uint256)
    {
        _checkFullRange(params.tickLower, params.tickUpper);
        return super._getRemoveLiquidity(params);
    }

    function _getPositionSalt(address, bytes32) internal view override returns (bytes32) {
        return bytes32(0);
    }

    // Keep the shared position's fees in the hook
    function _handleAccruedFees(CallbackData memory, BalanceDelta, BalanceDelta feesAccrued) internal override {
        PoolKey memory key = poolKey();
        key.currency0.take(poolManager, address(this), uint256(int256(feesAccrued.amount0())), false);
        key.currency1.take(poolManager, address(this), uint256(int256(feesAccrued.amount1())), false);
    }

    function _checkFullRange(int24 tickLower, int24 tickUpper) private view {
        int24 tickSpacing = poolKey().tickSpacing;
        if (tickLower != TickMath.minUsableTick(tickSpacing) || tickUpper != TickMath.maxUsableTick(tickSpacing)) {
            revert InvalidTickRange();
        }
    }

    // Exclude from coverage report
    function test() public override {}
}
