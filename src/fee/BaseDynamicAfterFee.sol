// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.2) (src/fee/BaseDynamicAfterFee.sol)

pragma solidity ^0.8.26;

// External imports
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// Internal imports
import {BaseHook} from "../base/BaseHook.sol";
import {IHookEvents} from "../interfaces/IHookEvents.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

/**
 * @dev Base implementation for dynamic target hook fees applied after swaps.
 *
 * Enables to enforce a dynamic target determined by {_getTargetUnspecified} for the unspecified currency of the swap,
 * where if the swap outcome results better than the target, any positive difference is taken as a hook fee, being
 * posteriorily handled or distributed by the hook via {_afterSwapHandler}.
 *
 * The target is determined after the swap, so {_getTargetUnspecified} receives the `BalanceDelta` the swap produced
 * and can size the target against the amount the swap filled rather than the amount it requested.
 *
 * NOTE: In order to use this hook, the inheriting contract must implement {_getTargetUnspecified} to determine the target,
 * and {_afterSwapHandler} to handle accumulated fees.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseDynamicAfterFee is BaseHook, IHookEvents {
    using SafeCast for *;
    using CurrencySettler for Currency;

    /**
     * @dev Enforce the target unspecified amount to the unspecified currency of the swap.
     *
     * When the swap is `exactInput` and the unspecified target is surpassed, the difference is decreased from the
     * output as a hook fee. Accordingly, when the swap is `exactOutput` and the unspecified target is not reached, the
     * difference is increased to the input as a hook fee. Note that the fee is always applied to the unspecified
     * currency of the swap, regardless of the swap direction.
     *
     * The fees are minted to this hook as ERC-6909 tokens, which can then be distributed in {_afterSwapHandler}
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        (uint256 targetUnspecifiedAmount, bool applyTarget) =
            _getTargetUnspecified(sender, key, params, delta, hookData);

        // Skip if the target unspecified amount should not be applied
        if (!applyTarget) return (this.afterSwap.selector, 0);

        // Fee defined in the unspecified currency of the swap
        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        // Get the absolute unspecified amount
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        // Get the exact input flag
        bool exactInput = params.amountSpecified < 0;

        // slither-disable-next-line uninitialized-local
        uint256 feeAmount;

        // If the swap is exactInput, any fee should be decreased from the swap output
        if (exactInput) {
            // If the swap output exceeds the target, decrease it by the difference as a hook fee
            if (unspecifiedAmount.toUint256() > targetUnspecifiedAmount) {
                feeAmount = unspecifiedAmount.toUint256() - targetUnspecifiedAmount;
            }
            // If the swap output is less or equal than the target, behave as a no-op
        }
        // If the swap is exactOutput, any fee should be increased to the swap input
        else {
            // If the swap input is less than the target, increase it by the difference as a hook fee
            if (unspecifiedAmount.toUint256() < targetUnspecifiedAmount) {
                feeAmount = targetUnspecifiedAmount - unspecifiedAmount.toUint256();
            }
            // If the swap input is greater or equal than the target, behave as a no-op
        }

        if (feeAmount > 0) {
            // Mint ERC-6909 tokens for unspecified currency fee and call handler
            unspecified.take(poolManager, address(this), feeAmount.toUint128(), true);
            _afterSwapHandler(key, params, delta, targetUnspecifiedAmount, feeAmount);

            // Emit the swap event with the amounts ordered correctly
            if (unspecified == key.currency0) {
                emit HookFee(PoolId.unwrap(key.toId()), sender, feeAmount.toUint128(), 0);
            } else {
                emit HookFee(PoolId.unwrap(key.toId()), sender, 0, feeAmount.toUint128());
            }
        }

        return (this.afterSwap.selector, feeAmount.toInt256().toInt128());
    }

    /**
     * @dev Return the target unspecified amount to be enforced on the swap that `delta` reports.
     *
     * IMPORTANT: The call happens after the swap, so anything this function reads from the `PoolManager` is
     * the state the swap left behind. An implementation that needs the state as it stood before the swap must
     * capture it in its own `beforeSwap`.
     *
     * @return targetUnspecifiedAmount The target unspecified amount, defined in the unspecified currency of the swap.
     * @return applyTarget The apply flag, which can be set to `false` to skip applying the target output.
     */
    function _getTargetUnspecified(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual returns (uint256 targetUnspecifiedAmount, bool applyTarget);

    /**
     * @dev Customizable handler called after `_afterSwap` to handle or distribute the fees.
     *
     * @param key The pool key.
     * @param params The swap parameters.
     * @param delta The balance delta.
     * @param targetUnspecifiedAmount The target unspecified amount.
     * @param feeAmount The fee amount.
     *
     * WARNING: If the underlying unspecified currency is native, the implementing contract must ensure that it can
     * receive and handle it when redeeming.
     */
    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint256 targetUnspecifiedAmount,
        uint256 feeAmount
    ) internal virtual;

    /**
     * @dev Set the hook permissions, specifically {afterSwap} and {afterSwapReturnDelta}.
     *
     * NOTE: `beforeSwap` is not requested. A hook that needs it must enable it here and implement
     * {BaseHook-_beforeSwap}, which reverts otherwise.
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
