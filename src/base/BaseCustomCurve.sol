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

    /**
     * @dev Liquidity can only be deposited directly to the hook.
     */
    error OnlyDirectLiquidity();

    /**
     * @dev Set the pool manager.
     */
    constructor(IPoolManager _poolManager, string memory _name, string memory _symbol)
        BaseCustomAccounting(_poolManager, _name, _symbol)
    {}

    /**
     * @dev Force liquidity to only be added directly to the hook.
     *
     * Note that the parent contract must implement the necessary functions to allow liquidity to be added directly to the hook.
     */
    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert OnlyDirectLiquidity();
    }

    /**
     * @inheritdoc BaseCustomAccounting
     */
    function _getAmount(uint256 amountIn, Currency input, Currency output, bool zeroForOne, bool exactInput)
        internal
        override
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

    /**
     * @dev Set the hook permissions, specifically `beforeAddLiquidity`, `beforeSwap` and `beforeSwapReturnDelta`.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
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
