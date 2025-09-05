// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.1.0) (src/utils/LiquidityMath.sol)

pragma solidity ^0.8.24;

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @dev Library with helper functions for liquidity math.
 */
library LiquidityMath {
    using SafeCast for *;

    /**
     * @dev Calculates the delta necessary to provide a given `liquidity` amount to a pool, based
     * on the pool's `currentTick` and `currentSqrtPriceX96` and the `tickLower` and `tickUpper`
     * boundaries.
     */
    function calculateDeltaForLiquidity(
        uint128 liquidity,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint160 currentSqrtPriceX96
    ) internal pure returns (BalanceDelta delta) {
        if (currentTick < tickLower) {
            delta = toBalanceDelta(
                SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), int128(liquidity)
                ).toInt128(),
                0
            );
        } else if (currentTick < tickUpper) {
            delta = toBalanceDelta(
                SqrtPriceMath.getAmount0Delta(
                    currentSqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), int128(liquidity)
                ).toInt128(),
                SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtPriceAtTick(tickLower), currentSqrtPriceX96, int128(liquidity)
                ).toInt128()
            );
        } else {
            delta = toBalanceDelta(
                0,
                SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), int128(liquidity)
                ).toInt128()
            );
        }
    }
}
