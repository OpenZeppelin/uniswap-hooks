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

/**
 * @dev Base implementation to apply fees to a hook. These fees are applied to swap amounts in the unspecified currency.
 * These fees are independent of the pool's LP fee, charged after the swap and the amount taken as fee are deposited into the hook.
 *
 * NOTE that this hook can be used by multiple pools and currencies can overlap between them.
 * That's why the `withdrawFees` function takes a `Currency[]` as argument instead of a `PoolKey` for example.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v1.2.0_
 */
abstract contract BaseHookFee is BaseHook, IHookEvents {
    using SafeCast for uint256;
    using CurrencySettler for Currency;

    /// @dev The maximum fee that can be applied to a hook. (100%)
    uint256 internal constant MAX_FEE = 1e6;

    /// @dev Fee is higher than the maximum allowed fee.
    error FeeTooHigh();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Get the fee to be applied after the swap. Takes the `address` `sender`, a `PoolKey` `key`,
     * the `SwapParams` `params` and `hookData` as arguments and returns the `fee` to be applied.
     */
    function _getHookFee(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal view virtual returns (uint256);

    /**
     * @dev Withdraws the fees from the hook. Takes the `Currency[]` `currencies` as arguments.
     */
    function withdrawFees(Currency[] calldata currencies) external virtual;

    /**
     * @dev Hooks into the `afterSwap` hook to apply the hook fee to the unspecified currency.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        if (unspecifiedAmount == 0) {
            return (this.afterSwap.selector, 0);
        }

        if (unspecifiedAmount < 0) {
            unspecifiedAmount = -unspecifiedAmount;
        }

        uint256 fee = _getHookFee(sender, key, params, hookData);

        if (fee == 0) return (this.afterSwap.selector, 0);

        if (fee > MAX_FEE) revert FeeTooHigh();

        uint256 feeAmount = FullMath.mulDiv(uint256(uint128(unspecifiedAmount)), fee, MAX_FEE);

        // Take the fee amount to the hook. Note that having `claims` as false means that the currency will be transferred to the hook
        // as ERC20 or native tokens, not as a claim.
        unspecified.take(poolManager, address(this), feeAmount, false);

        // Emit the swap event with the amounts ordered correctly
        if (unspecified == key.currency0) {
            emit HookFee(PoolId.unwrap(key.toId()), sender, feeAmount.toUint128(), 0);
        } else {
            emit HookFee(PoolId.unwrap(key.toId()), sender, 0, feeAmount.toUint128());
        }

        return (this.afterSwap.selector, feeAmount.toInt128());
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
