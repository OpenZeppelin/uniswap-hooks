// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.1.0) (src/general/AntiSandwichHook.sol)

pragma solidity ^0.8.24;

// Internal imports
import {BaseDynamicAfterFee} from "../fee/BaseDynamicAfterFee.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

// External imports
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
/**
 * @dev Sandwich-resistant hook, based on
 * https://github.com/cairoeth/sandwich-resistant-hook/blob/master/src/srHook.sol[this]
 * implementation.
 *
 * This hook implements the sandwich-resistant AMM design introduced
 * https://www.umbraresearch.xyz/writings/sandwich-resistant-amm[here]. Specifically,
 * this hook guarantees that no swaps get filled at a price better than the price at
 * the beginning of the slot window (i.e. one block).
 *
 * Within a slot window, swaps impact the pool asymmetrically for buys and sells.
 * When a buy order is executed, the offer on the pool increases in accordance with
 * the xy=k curve. However, the bid price remains constant, instead increasing the
 * amount of liquidity on the bid. Subsequent sells eat into this liquidity, while
 * decreasing the offer price according to xy=k.
 *
 * NOTE: Swaps in the other direction do not get the positive price difference
 * compared to the initial price before the first swap in the block, i.e. the anti sandwich mechanism
 * is only applied when zeroForOne = true.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v1.1.0_
 */

contract AntiSandwichHook is BaseDynamicAfterFee {
    using Pool for *;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /// @dev Represents a checkpoint of the pool state at the beginning of a block.
    struct Checkpoint {
        uint48 blockNumber;
        Pool.State state;
    }

    /// @dev Maps each pool to its last checkpoint.
    mapping(PoolId id => Checkpoint) private _lastCheckpoints;

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    /**
     * @dev Handles the before swap hook, setting up checkpoints at the beginning of blocks
     * and calculating target outputs for subsequent swaps.
     *
     * For the first swap in a block:
     * - Saves the current pool state as a checkpoint
     *
     * For subsequent swaps in the same block:
     * - Calculates a target output based on the beginning-of-block state
     * - Sets the inherited `_targetOutput` and `_applyTargetOutput` variables to enforce price limits
     *
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];

        // update the top-of-block `slot0` if new block
        if (_lastCheckpoint.blockNumber != _getBlockNumber()) {
            _lastCheckpoint.state.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId)));

            _lastCheckpoint.blockNumber = _getBlockNumber();

            // iterate over ticks
            (, int24 tickAfter,,) = poolManager.getSlot0(poolId);

            if (tickAfter > _lastCheckpoint.state.slot0.tick()) {
                for (int24 tick = _lastCheckpoint.state.slot0.tick(); tick < tickAfter; tick += key.tickSpacing) {
                    (
                        uint128 liquidityGross,
                        int128 liquidityNet,
                        uint256 feeGrowthOutside0X128,
                        uint256 feeGrowthOutside1X128
                    ) = poolManager.getTickInfo(poolId, tick);

                    _lastCheckpoint.state.ticks[tick].liquidityGross = liquidityGross;
                    _lastCheckpoint.state.ticks[tick].liquidityNet = liquidityNet;
                    _lastCheckpoint.state.ticks[tick].feeGrowthOutside0X128 = feeGrowthOutside0X128;
                    _lastCheckpoint.state.ticks[tick].feeGrowthOutside1X128 = feeGrowthOutside1X128;
                }
            } else {
                for (int24 tick = _lastCheckpoint.state.slot0.tick(); tick > tickAfter; tick -= key.tickSpacing) {
                    (
                        uint128 liquidityGross,
                        int128 liquidityNet,
                        uint256 feeGrowthOutside0X128,
                        uint256 feeGrowthOutside1X128
                    ) = poolManager.getTickInfo(poolId, tick);

                    _lastCheckpoint.state.ticks[tick].liquidityGross = liquidityGross;
                    _lastCheckpoint.state.ticks[tick].liquidityNet = liquidityNet;
                    _lastCheckpoint.state.ticks[tick].feeGrowthOutside0X128 = feeGrowthOutside0X128;
                    _lastCheckpoint.state.ticks[tick].feeGrowthOutside1X128 = feeGrowthOutside1X128;
                }
            }
            (_lastCheckpoint.state.feeGrowthGlobal0X128, _lastCheckpoint.state.feeGrowthGlobal1X128) =
                poolManager.getFeeGrowthGlobals(poolId);
            _lastCheckpoint.state.liquidity = poolManager.getLiquidity(poolId);
        }

        return super._beforeSwap(sender, key, params, hookData);
    }

    /**
     * @dev Handles the after swap hook, initializing the full pool state checkpoint for the first
     * swap in a block and updating the target output if needed.
     *
     * For the first swap in a block:
     * - Saves a detailed checkpoint of the pool state including liquidity and tick information
     * - This checkpoint will be used for subsequent swaps to calculate fair execution prices
     *
     * For all swaps:
     * - Caps the target output to the actual swap amount to prevent excessive fee collection
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (!_applyTargetOutput) {
            return (this.afterSwap.selector, 0);
        }

        int128 unspecifiedAmount = (params.amountSpecified < 0 == params.zeroForOne) ? delta.amount1() : delta.amount0();
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? (key.currency1) : (key.currency0);
        bool exactInput = params.amountSpecified < 0;

        if (!exactInput && _targetOutput > uint256(uint128(unspecifiedAmount))) {
            // In this case, the swapper has a fixed output and `_targetOutput` is greater than the input amount.
            // In order to protect against the sandwich attack, we increase the input amount to `_targetOutput`.
            uint256 payAmount = _targetOutput - uint256(uint128(unspecifiedAmount));

            unspecified.take(poolManager, address(this), payAmount, true);

            _afterSwapHandler(key, params, delta, _targetOutput, payAmount);

            return (this.afterSwap.selector, int128(uint128(payAmount)));
        }

        return super._afterSwap(sender, key, params, delta, hookData);
    }

    /**
     * @dev Returns the current block number.
     */
    function _getBlockNumber() internal view virtual returns (uint48) {
        return uint48(block.number);
    }

    /**
     * @dev Calculates the fair output amount based on the pool state at the beginning of the block.
     * This prevents sandwich attacks by ensuring trades can't get better prices than what was available
     * at the start of the block. Note that the output calculated could mean either input or output, depending
     * if it's an exact input or output swap. In cases of zeroForOne == true, the target output is not applicable,
     * the max uint256 value is returned only as a flag.
     *
     * The anti-sandwich mechanism works by:
     * * For currency0 to currency1 swaps (zeroForOne = true): The pool behaves normally with xy=k curve
     * * For currency1 to currency0 swaps (zeroForOne = false): The price is fixed at the beginning-of-block
     *   price, which prevents attackers from manipulating the price within a block
     */
    function _getTargetOutput(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (uint256 targetOutput, bool applyTargetOutput)
    {
        if (params.zeroForOne) {
            // when zeroForOne == true, the xy=k curve is used, so the target output doesn't matter, since it's not going to be used
            // we return the max value to indicate that the target output is not applicable
            return (type(uint256).max, false);
        }

        PoolId poolId = key.toId();
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];

        // calculate target output
        // NOTE: this functions does not execute the swap, it only calculates the output of a swap in the given state
        (BalanceDelta targetDelta,,,) = Pool.swap(
            _lastCheckpoint.state,
            Pool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                lpFeeOverride: 0
            })
        );

        int128 target =
            (params.amountSpecified < 0 == params.zeroForOne) ? targetDelta.amount1() : targetDelta.amount0();

        if (target < 0) target = -target;

        targetOutput = uint256(uint128(target));
        applyTargetOutput = true;
    }

    /**
     * @dev Handles the excess tokens collected during the swap due to the anti-sandwich mechanism.
     * When a swap executes at a worse price than what's currently available in the pool (due to
     * enforcing the beginning-of-block price), the excess tokens are donated back to the pool
     * to benefit all liquidity providers.
     */
    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        uint256,
        uint256 feeAmount
    ) internal override {
        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? (key.currency1) : (key.currency0);
        (uint256 amount0, uint256 amount1) = unspecified == key.currency0
            ? (uint256(uint128(feeAmount)), uint256(0))
            : (uint256(0), uint256(uint128(feeAmount)));

        // reset apply flag
        _applyTargetOutput = false;

        // settle and donate execess tokens to the pool
        poolManager.donate(key, amount0, amount1, "");
        unspecified.settle(poolManager, address(this), feeAmount, true);
    }

    /**
     * @dev Set the hook permissions, specifically `beforeSwap`, `afterSwap`, and `afterSwapReturnDelta`.
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
