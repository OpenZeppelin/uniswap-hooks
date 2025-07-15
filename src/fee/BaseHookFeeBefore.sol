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
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

abstract contract BaseHookFeeBefore is BaseHook, IHookEvents {
    using SafeCast for *;
    using CurrencySettler for Currency;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    error HookFeeTooLarge();

    function _getBeforeSwapHookFee(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal view virtual returns (uint128 specifiedFee, uint128 unspecifiedFee);

    /**
     * @dev Hooks into the `afterSwap` hook to apply the hook fee to the unspecified currency.
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) {
        (Currency unspecified, Currency specified) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, key.currency0)
            : (key.currency0, key.currency1);

        (uint128 specifiedFee, uint128 unspecifiedFee) = _getBeforeSwapHookFee(sender, key, params, hookData);

        if (unspecifiedFee == 0 && specifiedFee == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        int256 amountSpecified = params.amountSpecified;

        // `amountSpecified` is negative if the swap is `exactInput`, and it is positive if the swap is `exactOutput`.
        if (amountSpecified < 0) amountSpecified = -amountSpecified;
        
        // Is not possible to take a larger or equal `specified currency` hook fee than the origin of the swap.
        if (specifiedFee >= amountSpecified.toUint256().toUint128()) revert HookFeeTooLarge();

        // Is not possible to take a larger `unspecified currency` hook fee than the result of the swap
        // However, we cannot validate the `unspecifiedFee` since the swap didn't happen yet.
        // @TBD validate if this is a real problem or if the PoolManager handles the scenario where we attempt to larger amount than there is. 
        // if (unspecifiedFee > ...) revert HookFeeTooLarge();

        // Take the fee amount to the hook. Note that having `claims` as true means that the currency will be transferred to the hook
        // as ERC-6909 claims instead of performing an erc20 transfer.
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