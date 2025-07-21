// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/fee/BaseHookFee.sol)

pragma solidity ^0.8.24;

// internal imports
import {IHookEvents} from "../interfaces/IHookEvents.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

// external imports
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/**
 * @dev Base implementation for taking hook fees after swaps.
 *
 * Taking hook fees after swaps is ideal when your hook fee depends on the `delta` result of the swap.
 * However, a drawback is that only the `unspecifiedAmount` can be modified after a swap already happened.
 * If you need to deduct fees from the `specifiedCurrency`, consider using {BaseBeforeSwapHookFee} instead.
 */
abstract contract BaseAfterSwapHookFee is BaseHook, IHookEvents {
    using SafeCast for *;
    using CurrencySettler for Currency;

    /**
     * @dev Thrown when the hook attempts to take a fee larger than possible.
     */
    error AfterSwapHookFeeTooLarge();

    /**
     * @dev Determine the hook fee to be applied during the `afterSwap` hook.
     */
    function _getAfterSwapHookFee(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal view virtual returns (uint128 unspecifiedFee);

    /**
     * @dev Hooks into the `afterSwap` hook to apply the hook fee to the unspecified currency.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4 selector, int128 deltaUnspecified) {
        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        // If the `unspecifiedAmount` is 0, there is no currency to take a hook fee from.
        if (unspecifiedAmount == 0) return (this.afterSwap.selector, 0);

        // Get the hook fee to be applied during the `afterSwap` hook.
        uint128 unspecifiedFee = _getAfterSwapHookFee(sender, key, params, delta, hookData);

        // If the `unspecifiedFee` is 0, there is no fee to take.
        if (unspecifiedFee == 0) return (this.afterSwap.selector, 0);

        // `unspecifiedAmount` is negative if the swap is `exactOutput`, and positive if the swap is `exactInput`.
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        // Is not possible to take a larger `unspecified currency` hook fee than the result of the swap
        if (unspecifiedFee > unspecifiedAmount.toUint128()) revert AfterSwapHookFeeTooLarge();

        // Take the fee amount to the hook as ERC-6909 claims instead of performing an erc20 transfer.
        unspecified.take(poolManager, address(this), unspecifiedFee, true);

        // Emit the swap event with the amounts ordered correctly
        if (unspecified == key.currency0) {
            emit HookFee(PoolId.unwrap(key.toId()), sender, unspecifiedFee, 0);
        } else {
            emit HookFee(PoolId.unwrap(key.toId()), sender, 0, unspecifiedFee);
        }

        return (this.afterSwap.selector, unspecifiedFee.toInt128());
    }

    /**
     * @dev Set the hook permissions, specifically {afterSwap} and {afterSwapReturnDelta}.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
