// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.1.0) (src/general/AntiSandwichHook.sol)

pragma solidity ^0.8.24;

// Internal imports
import {BaseDynamicAfterFee} from "../fee/BaseDynamicAfterFee.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

// External imports
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

/**
 * @dev This hook implements the sandwich-resistant AMM design introduced
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
 * In order to use this hook, the inheriting contract must implement the {_handleCollectedFees} function
 * to determine how to handle the collected fees from the anti-sandwich mechanism.
 *
 * NOTE: The Anti-sandwich mechanism only protects swaps in the zeroForOne swap direction.
 * Swaps in the !zeroForOne direction are not protected by this hook design.
 *
 * WARNING: Since this hook makes MEV not profitable, there's not as much arbitrage in
 * the pool, making prices at beginning of the block not necessarily close to market price.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v1.1.0_
 */
abstract contract AntiSandwichHook is BaseDynamicAfterFee {
    using Pool for *;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for *;

    /// @dev Represents a checkpoint of the pool state at the beginning of a block.
    struct Checkpoint {
        uint48 blockNumber;
        Pool.State state;
    }

    /// @dev Maps each pool to its last checkpoint.
    mapping(PoolId id => Checkpoint) private _lastCheckpoints;

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    /**
     * @dev Handles the before swap hook.
     *
     * For the first swap in a block, it saves the current pool state as a checkpoint.
     *
     * For subsequent swaps in the same block, it calculates a target output based on the beginning-of-block state,
     * and sets the inherited `_targetOutput` and `_applyTargetOutput` variables to enforce price limits in {_afterSwap}.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Checkpoint storage _lastCheckpoint = _lastCheckpoints[poolId];

        uint48 currentBlock = _getBlockNumber();

        // update the top-of-block `slot0` if new block
        if (_lastCheckpoint.blockNumber != currentBlock) {
            _lastCheckpoint.state.slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId)));
            _lastCheckpoint.blockNumber = currentBlock;

            // iterate over ticks
            (, int24 currentTick,,) = poolManager.getSlot0(poolId);

            int24 lastTick = _lastCheckpoint.state.slot0.tick();
            int24 step = currentTick > lastTick ? key.tickSpacing : -key.tickSpacing;

            for (int24 tick = lastTick; tick != currentTick; tick += step) {
                (
                    _lastCheckpoint.state.ticks[tick].liquidityGross,
                    _lastCheckpoint.state.ticks[tick].liquidityNet,
                    _lastCheckpoint.state.ticks[tick].feeGrowthOutside0X128,
                    _lastCheckpoint.state.ticks[tick].feeGrowthOutside1X128
                ) = poolManager.getTickInfo(poolId, tick);
            }

            (_lastCheckpoint.state.feeGrowthGlobal0X128, _lastCheckpoint.state.feeGrowthGlobal1X128) =
                poolManager.getFeeGrowthGlobals(poolId);
            _lastCheckpoint.state.liquidity = poolManager.getLiquidity(poolId);
        }

        return super._beforeSwap(sender, key, params, hookData);
    }

    /**
     * @dev Handles the after swap hook.
     *
     * Caps the obtained output from the swap to the target output determined during the {_beforeSwap} hook.
     * Handles the excess output afterwards via {_afterSwapHandler}.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        uint256 targetOutput = _getTransientTargetOutput();

        // Reset storage target output to 0 and use one stored in memory
        // _setTransientTargetOutput(0);

        if (!_getTransientApplyTargetOutput()) {
            return (this.afterSwap.selector, 0);
        }

        // Fee defined in the unspecified currency of the swap
        (Currency unspecified, int128 unspecifiedAmount) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        // If fee is on output, get the absolute output amount
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        bool exactInput = params.amountSpecified < 0;

        if (!exactInput && targetOutput > unspecifiedAmount.toUint256()) {
            // In this case, the swapper has a fixed output and `_targetOutput` is greater than the input amount.
            // In order to protect against the sandwich attack, we increase the input amount to `_targetOutput`.
            uint256 payAmount = targetOutput - unspecifiedAmount.toUint256();

            unspecified.take(poolManager, address(this), payAmount, true);

            _afterSwapHandler(key, params, delta, targetOutput, payAmount);

            return (this.afterSwap.selector, payAmount.toInt256().toInt128());
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
     * @dev Calculates the output amount based on the pool state at the beginning of the block.
     * This prevents sandwich attacks by ensuring trades can't get better prices than what was available
     * at the start of the block. Note that the calculated output could either be input or output, depending
     * if it's an exactInput or outputOutput swap. In cases of zeroForOne == true, the target output is not
     * applicable, and the max uint256 value is returned as a flag only.
     *
     * The anti-sandwich mechanism works such as:
     *
     * - For currency0 to currency1 swaps (zeroForOne = true): The pool behaves normally with xy=k curve.
     * - For currency1 to currency0 swaps (zeroForOne = false): The price is fixed at the beginning-of-block
     *   price, which prevents attackers from manipulating the price within a block.
     */
    function _getTargetOutput(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (uint256 targetOutput, bool applyTargetOutput)
    {
        if (params.zeroForOne) {
            // when zeroForOne == true, the xy=k curve is used, so the target output doesn't matter, since it's not going to be used
            // we return the max value to indicate that the target output is not applicable
            return (type(uint256).max, false);
        }

        Checkpoint storage _lastCheckpoint = _lastCheckpoints[key.toId()];

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

        targetOutput = target.toUint256();
        applyTargetOutput = true;
    }

    /**
     * @dev Handles the excess tokens collected during the swap due to the anti-sandwich mechanism.
     * When a swap executes at a worse price than what's currently available in the pool (due to
     * enforcing the beginning-of-block price).
     */
    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        uint256,
        uint256 feeAmount
    ) internal virtual override {
        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? (key.currency1) : (key.currency0);

        // reset apply flag
        // slither-disable-next-line reentrancy-no-eth
        _setTransientApplyTargetOutput(false);

        _handleCollectedFees(key, unspecified, feeAmount);
    }

    /**
     * @dev Handles the fees collected via the anti-sandwich protection in {_afterSwap}.
     *
     * NOTE: Must be implemented by the inheriting contract.
     */
    function _handleCollectedFees(PoolKey calldata key, Currency currency, uint256 feeAmount) internal virtual;

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
