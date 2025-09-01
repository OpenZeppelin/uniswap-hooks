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
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @dev Base implementation for taking hook fees before swaps.
 *
 * Taking hook fees before swaps is ideal when your hook fee must be taken from the `specifiedAmount` and/or
 * the `unspecifiedAmount` of the swap. However, since the swap didn't happen yet, a drawback is that the `delta`
 * result of the swap is not yet available. If your hook fee depends on the `delta` result of the swap,
 * consider using {BaseAfterSwapHookFee} instead.
 * 
 * NOTE: on `exactOutput` swaps hook fees can't be taken from `specifiedAmount`.
 * 
 * NOTE: Since the swap didn't yet happen, the `delta` result of the swap is not available, and the `unspecifiedFee`
 * can't be set but cannot be validated in this hook.
 */
abstract contract BaseBeforeSwapHookFee is BaseHook, IHookEvents {
    using SafeCast for *;
    using CurrencySettler for Currency;

    /**
     * @dev Thrown when the hook attempts to take a fee larger than possible.
     */
    error BeforeSwapHookFeeTooLarge();

    /**
     * @dev Determine the hook fee to be applied during the `beforeSwap` hook.
     */
    function _getBeforeSwapHookFee(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal view virtual returns (uint128 specifiedFee, uint128 unspecifiedFee);

    /**
     * @dev Hooks into the `beforeSwap` hook to apply the hook fee to the specified and unspecified currencies.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride)
    {
        (Currency unspecified, Currency specified) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, key.currency0)
            : (key.currency0, key.currency1);

        // Get the hook fee to be applied during the `beforeSwap` hook.
        (uint128 specifiedFee, uint128 unspecifiedFee) = _getBeforeSwapHookFee(sender, key, params, hookData);

        // If the `unspecifiedFee` and `specifiedFee` are 0, there is no fee to take.
        if (unspecifiedFee == 0 && specifiedFee == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        int256 amountSpecified = params.amountSpecified;

        // `amountSpecified` is negative if the swap is `exactInput`, and it is positive if the swap is `exactOutput`.
        if (amountSpecified < 0) amountSpecified = -amountSpecified;

        // Is not possible to take a larger than or equal `specifiedFee` hook fee than the specified amount of the swap.
        if (specifiedFee >= amountSpecified.toUint256().toUint128()) revert BeforeSwapHookFeeTooLarge();

        // Take the fee amount to the hook as ERC-6909 claims instead of performing an erc20 transfer.
        if (specifiedFee > 0) specified.take(poolManager, address(this), specifiedFee, true);
        if (unspecifiedFee > 0) unspecified.take(poolManager, address(this), unspecifiedFee, true);

        // Emit the swap event with the amounts ordered correctly
        if (unspecified == key.currency0) {
            emit HookFee(PoolId.unwrap(key.toId()), sender, unspecifiedFee, specifiedFee);
        } else {
            emit HookFee(PoolId.unwrap(key.toId()), sender, specifiedFee, unspecifiedFee);
        }

        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(specifiedFee), int128(unspecifiedFee)), 0);
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
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
