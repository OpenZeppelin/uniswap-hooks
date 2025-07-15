// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/fee/BaseHookFee.sol)

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
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

abstract contract BaseHookFeeAfter is BaseHook, IHookEvents {
    using SafeCast for *;
    using CurrencySettler for Currency;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    error HookFeeTooLarge();

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

        if (unspecifiedAmount == 0) return (this.afterSwap.selector, 0);

        // `unspecifiedAmount` is negative if the swap is `exactOutput`, and it is positive if the swap is `exactInput`.
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        uint128 unspecifiedFee = _getAfterSwapHookFee(sender, key, params, delta, hookData);

        if (unspecifiedFee == 0) return (this.afterSwap.selector, 0);

        // Is not possible to take a larger `unspecified currency` hook fee than the result of the swap
        if (unspecifiedFee > unspecifiedAmount.toUint128()) revert HookFeeTooLarge();

        // Take the fee amount to the hook. Note that having `claims` as true means that the currency will be transferred to the hook
        // as ERC-6909 claims instead of performing an erc20 transfer.
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