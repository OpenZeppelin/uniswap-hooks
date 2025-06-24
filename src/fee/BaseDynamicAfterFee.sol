// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/fee/BaseDynamicAfterFee.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHookEvents} from "src/interfaces/IHookEvents.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientSlot} from "openzeppelin/utils/TransientSlot.sol";
import {SlotDerivation} from "openzeppelin/utils/SlotDerivation.sol";

/**
 * @dev Base implementation for dynamic fees applied after swaps.
 *
 * In order to use this hook, the inheriting contract must define the {_getTargetOutput} and
 * {_afterSwapHandler} functions. The {_getTargetOutput} function returns the target output to
 * apply to the swap depending on the given apply flag. The {_afterSwapHandler} function is called
 * after the target output is applied to the swap and currency amount is received.
 *
 * NOTE: Even if `targetOutput` and `applyTargetOutput` are stored in transient storage,
 * they must be manually reseted after each swap in order to avoid state collisions in swaps batched
 * in a single transaction. See https://eips.ethereum.org/EIPS/eip-1153#Security-considerations
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseDynamicAfterFee is BaseHook, IHookEvents {
    using SafeCast for uint256;
    using CurrencySettler for Currency;
    using TransientSlot for *;
    using SlotDerivation for *;

    /**
     * @dev Target output exceeds swap amount.
     */
    error TargetOutputExceeds();

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.BaseDynamicAfterFee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BASE_DYNAMIC_AFTER_FEE_SLOT =
        0x573e65eb8119149aa4b92cb540f79645b8190fcaf67b1af773f62674fbe27900;

    uint256 private constant TARGET_OUTPUT_OFFSET = 0;
    uint256 private constant APPLY_TARGET_OUTPUT_OFFSET = 1;

    function _setTransientTargetOutput(uint256 value) internal {
        BASE_DYNAMIC_AFTER_FEE_SLOT.offset(TARGET_OUTPUT_OFFSET).asUint256().tstore(value);
    }

    function _setTransientApplyTargetOutput(bool value) internal {
        BASE_DYNAMIC_AFTER_FEE_SLOT.offset(APPLY_TARGET_OUTPUT_OFFSET).asBoolean().tstore(value);
    }

    function _getTransientTargetOutput() internal view returns (uint256) {
        return BASE_DYNAMIC_AFTER_FEE_SLOT.offset(TARGET_OUTPUT_OFFSET).asUint256().tload();
    }

    function _getTransientApplyTargetOutput() internal view returns (bool) {
        return BASE_DYNAMIC_AFTER_FEE_SLOT.offset(APPLY_TARGET_OUTPUT_OFFSET).asBoolean().tload();
    }

    /**
     * @dev Set the `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Sets the target output and apply flag to be used in the `afterSwap` hook.
     *
     * NOTE: The target output is reset to 0 in the `afterSwap` hook regardless of the apply flag.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get the target output and apply flag
        (uint256 targetOutput, bool applyTargetOutput) = _getTargetOutput(sender, key, params, hookData);

        // Set the target output and apply flag, overriding any previous values.
        _setTransientTargetOutput(targetOutput);
        _setTransientApplyTargetOutput(applyTargetOutput);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev Apply the target output to the unspecified currency of the swap using fees.
     * The fees are minted as ERC-6909 tokens, which can then be redeemed in the
     * {_afterSwapHandler} function. Note that if the underlying unspecified currency
     * is native, the implementing contract must ensure that it can receive native tokens
     * when redeeming.
     *
     * NOTE: The target output is reset to 0, regardless of the apply flag.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal virtual override returns (bytes4, int128) {
        uint256 targetOutput = _getTransientTargetOutput();

        // Reset storage target output to 0 and use one stored in memory
        _setTransientTargetOutput(0);

        // Skip if target output is not active
        // Note that we can return without reseting the apply flag if it is already false
        if (!_getTransientApplyTargetOutput()) {
            return (this.afterSwap.selector, 0);
        }

        // Fee defined in the unspecified currency of the swap
        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        // If fee is on output, get the absolute output amount
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        // Revert if the target output exceeds the swap amount
        if (targetOutput > uint128(unspecifiedAmount)) revert TargetOutputExceeds();

        // Calculate the fee amount, which is the difference between the swap amount and the target output
        uint256 feeAmount = uint128(unspecifiedAmount) - targetOutput;

        // Mint ERC-6909 tokens for unspecified currency fee and call handler
        if (feeAmount > 0) {
            unspecified.take(poolManager, address(this), feeAmount, true);
            _afterSwapHandler(key, params, delta, targetOutput, feeAmount);
        }

        // Emit the swap event with the amounts ordered correctly
        if (unspecified == key.currency0) {
            emit HookFee(PoolId.unwrap(key.toId()), sender, feeAmount.toUint128(), 0);
        } else {
            emit HookFee(PoolId.unwrap(key.toId()), sender, 0, feeAmount.toUint128());
        }

        return (this.afterSwap.selector, feeAmount.toInt128());
    }

    /**
     * @dev Return the target output to be enforced by the `afterSwap` hook using fees.
     *
     * IMPORTANT: The swap will revert if the target output exceeds the output unspecified amount from the swap.
     * In order to consume all of the output from the swap, set the target output to equal the output unspecified
     * amount and set the apply flag to `true`.
     *
     * @return targetOutput The target output, defined in the unspecified currency of the swap.
     * @return applyTargetOutput The apply flag, which can be set to `false` to skip applying the target output.
     */
    function _getTargetOutput(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        returns (uint256 targetOutput, bool applyTargetOutput);

    /**
     * @dev Handler called after applying the target output to a swap and receiving the currency amount.
     *
     * @param key The pool key.
     * @param params The swap parameters.
     * @param delta The balance delta from the swap.
     * @param targetOutput The target output, defined in the unspecified currency of the swap.
     * @param feeAmount The amount of the unspecified currency taken from the swap.
     */
    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint256 targetOutput,
        uint256 feeAmount
    ) internal virtual;

    /**
     * @dev Set the hook permissions, specifically {beforeSwap}, {afterSwap} and {afterSwapReturnDelta}.
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
