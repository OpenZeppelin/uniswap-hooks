// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/base/BaseCustomCurve.sol)

pragma solidity ^0.8.24;

import {BaseCustomAccounting} from "src/base/BaseCustomAccounting.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {console2 as console} from "forge-std/console2.sol";

/**
 * @dev Base implementation for custom curves.
 *
 * This contract allows to implement a custom curve (or any logic) for swaps, which overrides the default
 * v3-like concentrated liquidity implementation of Uniswap. By inheriting {BaseCustomAccounting}, the hook calls
 * the {_getAmountOutFromExactInput} or {_getAmountInForExactOutput} function to calculate the amount of tokens
 * to be taken or settled, and a return delta is created based on their outputs. This return delta is then
 * consumed by the `PoolManager`.
 *
 * NOTE: This base contract acts similarly to {BaseNoOp}, which means that the hook must hold the liquidity
 * for swaps.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseCustomCurve is BaseCustomAccounting {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    struct CallbackDataCustom {
        address sender;
        int128 amount0;
        int128 amount1;
    }

    /**
     * @dev Liquidity can only be deposited directly to the hook.
     */
    error OnlyDirectLiquidity();

    /**
     * @dev Set the PoolManager address.
     */
    constructor(IPoolManager _poolManager) BaseCustomAccounting(_poolManager) {}

    /**
     * @dev Force liquidity to only be added directly to the hook.
     *
     * Note that the parent contract must implement the necessary functions to allow liquidity to be added directly to the hook.
     */
    // TODO
    // function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
    //     internal
    //     pure
    //     override
    //     returns (bytes4)
    // {
    //     revert OnlyDirectLiquidity();
    // }

    function _getAddLiquidity(uint160, AddLiquidityParams memory params)
        internal
        virtual
        override
        returns (bytes memory, uint256)
    {
        (uint256 amount0, uint256 amount1, uint256 liquidity) = _getAmountIn(params);
        return (abi.encode(amount0.toInt128(), amount1.toInt128()), liquidity);
    }

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        virtual
        override
        returns (bytes memory, uint256)
    {
        (uint256 amount0, uint256 amount1, uint256 liquidity) = _getAmountOut(params);
        return (abi.encode(-amount0.toInt128(), -amount1.toInt128()), liquidity);
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Determine if the swap is exact input or exact output
        bool exactInput = params.amountSpecified < 0;

        // Determine which currency is specified and which is unspecified
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        // Get the positive specified amount
        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Get the amount of the unspecified currency to be taken or settled
        uint256 unspecifiedAmount = _getAmount(
            specifiedAmount,
            exactInput ? specified : unspecified,
            exactInput ? unspecified : specified,
            params.zeroForOne,
            exactInput
        );

        // New delta must be returned, so store in memory
        BeforeSwapDelta returnDelta;

        if (exactInput) {
            specified.take(poolManager, address(this), specifiedAmount, true);
            unspecified.settle(poolManager, address(this), unspecifiedAmount, true);

            // On exact input, amount0 is specified and amount1 is unspecified.
            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            unspecified.take(poolManager, address(this), unspecifiedAmount, true);
            specified.settle(poolManager, address(this), specifiedAmount, true);

            // On exact output, amount1 is specified and amount0 is unspecified.
            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        }

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    function _modifyLiquidity(bytes memory params) internal virtual override returns (BalanceDelta delta) {
        (int128 amount0, int128 amount1) = abi.decode(params, (int128, int128));
        delta =
            abi.decode(poolManager.unlock(abi.encode(CallbackDataCustom(msg.sender, amount0, amount1))), (BalanceDelta));
    }

    function _unlockCallback(bytes calldata rawData) internal virtual override returns (bytes memory) {
        CallbackDataCustom memory data = abi.decode(rawData, (CallbackDataCustom));
        console.log(data.amount0);
        console.log(data.amount1);

        int128 amount0;
        int128 amount1;

        // If liquidity amount is negative, remove liquidity from the pool. Otherwise, add liquidity to the pool.
        // When removing liquidity, burn ERC-6909 claim tokens and transfer tokens from pool to receiver.
        // When adding liquidity, mint ERC-6909 claim tokens and transfer tokens from receiver to pool.

        if (data.amount0 < 0) {
            poolKey.currency0.settle(poolManager, address(this), uint256(int256(-data.amount0)), true);
            poolKey.currency0.take(poolManager, data.sender, uint256(int256(-data.amount0)), false);
            amount0 = data.amount0;
        }

        if (data.amount1 < 0) {
            poolKey.currency1.settle(poolManager, address(this), uint256(int256(-data.amount1)), true);
            poolKey.currency1.take(poolManager, data.sender, uint256(int256(-data.amount1)), false);
            amount1 = data.amount1;
        }

        if (data.amount0 > 0) {
            poolKey.currency0.settle(poolManager, data.sender, uint256(int256(data.amount0)), false);
            poolKey.currency0.take(poolManager, address(this), uint256(int256(data.amount0)), true);
            amount0 = -data.amount0;
        }

        if (data.amount1 > 0) {
            poolKey.currency1.settle(poolManager, data.sender, uint256(int256(data.amount1)), false);
            poolKey.currency1.take(poolManager, address(this), uint256(int256(data.amount1)), true);
            amount1 = -data.amount1;
        }

        return abi.encode(toBalanceDelta(amount0, amount1));
    }

    function _getAmount(uint256 amountIn, Currency input, Currency output, bool zeroForOne, bool exactInput)
        internal
        virtual
        returns (uint256 amount)
    {
        return exactInput
            ? _getAmountOutFromExactInput(amountIn, input, output, zeroForOne)
            : _getAmountInForExactOutput(amountIn, input, output, zeroForOne);
    }

    /**
     * @dev Calculate the amount of tokens to be received by the swapper from an exact input amount.
     */
    function _getAmountOutFromExactInput(uint256 amountIn, Currency input, Currency output, bool zeroForOne)
        internal
        virtual
        returns (uint256 amountOut);

    /**
     * @dev Calculate the amount of tokens to be taken from the swapper for an exact output amount.
     */
    function _getAmountInForExactOutput(uint256 amountOut, Currency input, Currency output, bool zeroForOne)
        internal
        virtual
        returns (uint256 amountIn);

    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    /**
     * @dev Set the hook permissions, specifically `beforeAddLiquidity`, `beforeSwap` and `beforeSwapReturnDelta`.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
