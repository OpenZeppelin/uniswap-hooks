// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/fee/BaseHookFee.sol)

pragma solidity ^0.8.26;

// External imports
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// Internal imports
import {IHookEvents} from "../interfaces/IHookEvents.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

/**
 * @dev Base implementation for applying hook fees to the unspecified currency of the swap.
 * These fees are independent of the pool's LP fee and are charged as a percentage of the output
 * amount after the swap completes.
 *
 * NOTE: It is left to the implementing contract to handle the accumulated hook fees, such as distributing
 * or withdrawing them via ERC-6909 claims.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code base.
 *
 * _Available since v1.2.0_
 */
abstract contract BaseHookFee is BaseHook, IHookEvents {
    using SafeCast for *;
    using CurrencySettler for Currency;

    /// @dev Fee is higher than the maximum allowed fee.
    error HookFeeTooLarge();

    /// @dev The maximum fee that can be applied to a hook, expressed in hundredths of a bip (100%)
    uint24 internal constant MAX_HOOK_FEE = 1e6;

    /**
     * @dev Get the fee to be applied after the swap. Takes the `address` `sender`, a `PoolKey` `key`,
     * the `SwapParams` `params`, `BalanceDelta` `delta` and `hookData` as arguments and returns the `fee`
     * to be applied in hundredths of a bip. i.e. 1000000 = 100%
     */
    function _getHookFee(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal view virtual returns (uint24 fee);

    /**
     * @dev Hooks into the `afterSwap` hook to apply the hook fee to the unspecified currency.
     *
     * NOTE: The fee is calculated as a percentage of the output amount and taken as ERC-6909 claims.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        if (unspecifiedAmount == 0) return (this.afterSwap.selector, 0);

        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        uint24 hookFee = _getHookFee(sender, key, params, delta, hookData);

        if (hookFee == 0) return (this.afterSwap.selector, 0);

        if (hookFee > MAX_HOOK_FEE) revert HookFeeTooLarge();

        uint256 feeAmount = FullMath.mulDiv(uint256(unspecifiedAmount.toUint128()), hookFee, MAX_HOOK_FEE);

        // Take the fee amount to the hook as ERC-6909 claims in order to save gas,
        // which can be redeemed back for tokens with the PoolManager at any point.
        unspecified.take(poolManager(), address(this), feeAmount, true);

        // Emit the hook fee event with the amounts ordered correctly
        if (unspecified == key.currency0) {
            emit HookFee(PoolId.unwrap(key.toId()), sender, feeAmount.toUint128(), 0);
        } else {
            emit HookFee(PoolId.unwrap(key.toId()), sender, 0, feeAmount.toUint128());
        }

        return (this.afterSwap.selector, feeAmount.toInt128());
    }

    /* 
    * @dev Must be implemented to handle the accumulated hook fees, such as distributing or withdrawing them via ERC-6909 claims.
    */
    function handleHookFees(Currency[] memory currencies) public virtual;

    /**
     * @dev Returns the hook permissions, specifically enabling {afterSwap} and {afterSwapReturnDelta}.
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
