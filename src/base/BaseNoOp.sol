// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/base/BaseNoOp.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "src/lib/CurrencySettler.sol";

/**
 * @dev Base implementation for no-op hooks, which skips the v3-like swap implementation of the `PoolManager`.
 *
 * IMPORTANT: No-op hooks only support exact-input swaps. For exact-output swaps, the hook will not act
 * as a no-op, so they would be processed with the `PoolManager`'s implementation.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseNoOp is BaseHook {
    using SafeCast for uint256;
    using CurrencySettler for Currency;

    /**
     * @dev Set the `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev No-op exact-input swaps by returning a delta that nets out the specified amount to 0.
     */
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // No-op is only possible on exact-input swaps
        if (params.amountSpecified < 0) {
            // Determine which currency is specified
            Currency specified = params.zeroForOne ? key.currency0 : key.currency1;

            // Get the positive specified amount
            uint256 specifiedAmount = uint256(-params.amountSpecified);

            // Mint ERC-6909 claim token for the specified currency and amount
            specified.take(poolManager, address(this), specifiedAmount, true);

            // Return delta that nets out specified amount to 0.
            return (this.beforeSwap.selector, toBeforeSwapDelta(specifiedAmount.toInt128(), 0), 0);
        } else {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
    }

    /**
     * @dev Set the hook permissions, specifically `beforeSwap` and `beforeSwapReturnDelta`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
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
