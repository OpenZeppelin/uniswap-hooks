// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {LimitOrderHookMock} from "src/mocks/general/LimitOrderHookMock.sol";
import {LimitOrderHookHandler} from "./LimitOrderHookHandler.sol";
import {OrderKey} from "./helpers/OrderIdSet.sol";

/**
 * @dev Handler that also moves the price without recording it, as a subclass that swaps internally and
 * skips {LimitOrderHook-_fillCrossedOrders} does.
 *
 * Adds to the fuzzable surface:
 * - `unrecordedSwapTo`
 * - `unrecordedExcursion`
 */
contract LimitOrderHookUnrecordedHandler is LimitOrderHookHandler {
    /// @dev Recorded swaps whose crossed range moved against the swap, and the orders they filled.
    uint256 public ghost_opposedSwaps;
    uint256 public ghost_opposedFills;

    constructor(
        LimitOrderHookMock hook_,
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        PoolKey memory key_,
        address[] memory actors_,
        int24[] memory ticks_,
        uint256 liquidityMinBound_,
        uint256 liquidityMaxBound_,
        uint256 amountMinBound_,
        uint256 amountMaxBound_
    )
        LimitOrderHookHandler(
            hook_,
            manager_,
            swapRouter_,
            key_,
            actors_,
            ticks_,
            liquidityMinBound_,
            liquidityMaxBound_,
            amountMinBound_,
            amountMaxBound_
        )
    {}

    /// @dev Moves the price from inside the hook's own unlock callback and fills nothing.
    function unrecordedSwapTo(uint256 tickSeed, uint256 amountSeed)
        external
        recordCall("unrecordedSwapTo")
        stateTransition
    {
        int24 target = _tickFromSeed(tickSeed);
        vm.assume(target != _currentTick());

        hook.internalSwap(key, target, bound(amountSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND), false);
    }

    /// @dev Moves the price two spacings past a live order without recording it, then one spacing back with
    /// a recorded swap. The order stays converted and the crossed range moves against that swap. One action
    /// because the fuzzer rarely composes it from two.
    function unrecordedExcursion(uint256 idSeed, uint256 amountSeed)
        external
        recordCall("unrecordedExcursion")
        stateTransition
    {
        uint232 id = _liveOrderFromSeed(idSeed);
        vm.assume(id != 0);

        OrderKey memory orderKey = orderKeyOf(id);
        int24 spacing = key.tickSpacing;
        int24 target = orderKey.zeroForOne ? orderKey.tickLower + 3 * spacing : orderKey.tickLower - 2 * spacing;
        int24 back = orderKey.zeroForOne ? orderKey.tickLower + 2 * spacing : orderKey.tickLower - spacing;
        uint256 amount = bound(amountSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND);

        // an earlier unrecorded swap can leave the price past the order already
        int24 storedTick = _storedTick();
        vm.assume(orderKey.zeroForOne ? storedTick < target - 1 : storedTick > target + 1);

        hook.internalSwap(key, target, amount, false);

        int24 current = _currentTick();
        vm.assume(orderKey.zeroForOne ? current > back : current < back);

        _swap(orderKey.zeroForOne, amount, back);
    }

    /// @dev Counts the swaps whose crossed range rose while the swap sold currency0, or the reverse.
    function _swap(bool zeroForOne, uint256 amount, int24 tickLimit) internal override {
        int24 last = hook.getTickLowerLast(poolId);
        uint256 filledBefore = _filledCount();

        super._swap(zeroForOne, amount, tickLimit);

        int24 tickLowerNow = _storedTickLower();
        if (tickLowerNow == last || (tickLowerNow > last) != zeroForOne) return;

        ++ghost_opposedSwaps;
        ghost_opposedFills += _filledCount() - filledBefore;
    }

    function _filledCount() private view returns (uint256 count) {
        uint232[] memory ids = orderIds();
        for (uint256 i; i < ids.length; ++i) {
            (bool filled,,,,,,,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(ids[i]));
            if (filled) ++count;
        }
    }
}
