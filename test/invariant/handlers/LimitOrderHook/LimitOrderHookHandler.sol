// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {LimitOrderHookMock} from "src/mocks/general/LimitOrderHookMock.sol";
import {BaseHandler} from "../BaseHandler.sol";
import {OrderIdSet, LibOrderIdSet, OrderKey} from "./helpers/OrderIdSet.sol";

/**
 * @dev Handler for `LimitOrderHook` invariant campaigns.
 *
 * Fuzzeable surface of this handler:
 * - placeOrder
 * - cancelOrder
 * - withdraw
 * - swapTo
 * - swapRoundTrip
 */
contract LimitOrderHookHandler is BaseHandler {
    using StateLibrary for IPoolManager;
    using LibOrderIdSet for OrderIdSet;

    LimitOrderHookMock internal hook;
    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolKey internal key;
    PoolId internal poolId;

    /// @dev Every order id the handler has caused to be created, with the key it was created for.
    OrderIdSet internal ghost_orderIds;

    /// @dev Cumulative currency credited to an order's totals over its lifetime, from realized fees
    /// and from fill proceeds. Accumulated from positive deltas, so a reset of the totals does not
    /// erase the history.
    mapping(uint232 orderId => uint256) public ghost_credited0;
    mapping(uint232 orderId => uint256) public ghost_credited1;

    /// @dev Cumulative currency actually delivered to an actor by `withdraw` on an order's behalf.
    mapping(uint232 orderId => uint256) public ghost_paidOut0;
    mapping(uint232 orderId => uint256) public ghost_paidOut1;

    /// @dev Totals as last observed, the baseline the credited deltas are measured against.
    mapping(uint232 orderId => uint256) internal ghost_lastTotal0;
    mapping(uint232 orderId => uint256) internal ghost_lastTotal1;

    constructor(
        LimitOrderHookMock hook_,
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        PoolKey memory key_,
        address[] memory actors_,
        int24[] memory ticks_
    ) {
        _createActors(actors_);
        _createTicks(ticks_);

        hook = hook_;
        manager = manager_;
        swapRouter = swapRouter_;
        key = key_;
        poolId = key_.toId();

        IERC20Minimal(Currency.unwrap(key_.currency0)).approve(address(swapRouter_), type(uint256).max);
        IERC20Minimal(Currency.unwrap(key_.currency1)).approve(address(swapRouter_), type(uint256).max);
    }

    // ------------------ FUZZABLE SURFACE ------------------ //

    function placeOrder(uint256 actorSeed, uint256 tickSeed, bool zeroForOne, uint256 liquiditySeed) external {
        int24 tickLower = _tickFromSeed(tickSeed);

        // The hook reverts if the order is not placeable.
        vm.assume(_placeable(tickLower, zeroForOne));

        address actor = _actorFromSeed(actorSeed);
        uint128 liquidity = uint128(bound(liquiditySeed, 1e8, 1e14));

        vm.prank(actor);
        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        ghost_orderIds.add(_orderIdAt(tickLower, zeroForOne), OrderKey(tickLower, zeroForOne));

        _recordCredits();
        _recordCall("placeOrder");
    }

    function cancelOrder(uint256 actorSeed, uint256 tickSeed, bool zeroForOne) external {
        int24 tickLower = _tickFromSeed(tickSeed);

        uint232 id = _orderIdAt(tickLower, zeroForOne);
        vm.assume(id != 0);

        address actor = _actorFromSeed(actorSeed);
        (bool filled,,,,,) = _orderInfo(id);
        vm.assume(!filled);
        vm.assume(_liquidityOf(id, actor) > 0);

        vm.prank(actor);
        hook.cancelOrder(key, tickLower, zeroForOne, actor);

        _recordCredits();
        _recordCall("cancelOrder");
    }

    function withdraw(uint256 actorSeed, uint256 idSeed) external {
        vm.assume(ghost_orderIds.count() > 0);

        address actor = _actorFromSeed(actorSeed);
        uint232 id = ghost_orderIds.rand(idSeed);

        (bool filled,,,,,) = _orderInfo(id);
        vm.assume(filled);
        vm.assume(_liquidityOf(id, actor) > 0);

        uint256 balance0Before = _balanceOf(key.currency0, actor);
        uint256 balance1Before = _balanceOf(key.currency1, actor);

        vm.prank(actor);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(id), actor);

        ghost_paidOut0[id] += _balanceOf(key.currency0, actor) - balance0Before;
        ghost_paidOut1[id] += _balanceOf(key.currency1, actor) - balance1Before;

        _recordCredits();
        _recordCall("withdraw");
    }

    /// @dev Move the price to an arbitrary candidate tick, crossing whatever lies between. Fills
    /// every order the price moves past.
    function swapTo(uint256 tickSeed, uint256 amountSeed) external {
        int24 target = _tickFromSeed(tickSeed);
        int24 current = _currentTick();
        vm.assume(target != current);

        _swap(target < current, bound(amountSeed, 1e15, 1e20), target);

        _recordCredits();
        _recordCall("swapTo");
    }

    /**
     * @dev Price excursion into a tick range and back out, without crossing it.
     *
     * Fees accrue to any order at that tick and no order fills. Modelled as one action because a
     * round trip is a single market event, and because splitting it makes the fee-accrual state two
     * rare steps instead of one, which the fuzzer reaches far less often.
     */
    function swapRoundTrip(uint256 tickSeed, uint256 amountSeed) external {
        int24 tickLower = _tickFromSeed(tickSeed);
        int24 current = _currentTick();

        uint256 amountIn = bound(amountSeed, 1e15, 1e20);

        // an excursion only exists if the price starts outside the range
        vm.assume(current < tickLower || current >= tickLower + key.tickSpacing);

        if (current < tickLower) {
            _swap(false, amountIn, tickLower + key.tickSpacing / 2);
            _swap(true, amountIn, current);
        } else {
            _swap(true, amountIn, tickLower + key.tickSpacing / 2);
            _swap(false, amountIn, current);
        }

        _recordCredits();
        _recordCall("swapRoundTrip");
    }

    // ------------------ VIEWS ------------------ //

    function orderIds() external view returns (uint232[] memory) {
        return ghost_orderIds.ids;
    }

    function orderIdCount() external view returns (uint256) {
        return ghost_orderIds.count();
    }

    /// @dev The tick and direction `id` was created for.
    function orderKeyOf(uint232 id) external view returns (OrderKey memory) {
        return ghost_orderIds.keyOf(id);
    }

    /// @dev Order id registered for `tickLower` and `zeroForOne`, or zero when no order is active
    /// there. A non-zero result means the order is live, since the hook retires the key on fill and
    /// on the last cancel.
    function orderIdAt(int24 tickLower, bool zeroForOne) external view returns (uint232) {
        return _orderIdAt(tickLower, zeroForOne);
    }

    // --- internals ----------------------------------------------------------------------

    /**
     * @dev Accumulate every increase in a known order's totals into `ghost_credited`.
     *
     * Reads only, `ghost_lastTotal` is the previous observation the delta is measured against.
     * Called after each action rather than inside it, because a swap can fill orders at several
     * ticks at once and the affected ids are not known up front.
     */
    function _recordCredits() private {
        for (uint256 i; i < ghost_orderIds.count(); ++i) {
            uint232 id = ghost_orderIds.ids[i];
            (,,, uint256 total0, uint256 total1,) = _orderInfo(id);

            if (total0 > ghost_lastTotal0[id]) ghost_credited0[id] += total0 - ghost_lastTotal0[id];
            if (total1 > ghost_lastTotal1[id]) ghost_credited1[id] += total1 - ghost_lastTotal1[id];

            ghost_lastTotal0[id] = total0;
            ghost_lastTotal1[id] = total1;
        }
    }

    /// @dev Whether `placeOrder` accepts this key at the current price. A `zeroForOne` order sells
    /// currency0, so its range must sit strictly above the price; the reverse sells currency1 and
    /// its range must sit at or below it.
    function _placeable(int24 tickLower, bool zeroForOne) private view returns (bool) {
        int24 current = _currentTick();
        return zeroForOne ? current < tickLower : current >= tickLower + key.tickSpacing;
    }

    function _swap(bool zeroForOne, uint256 amountIn, int24 tickLimit) private {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLimit)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _orderInfo(uint232 id)
        private
        view
        returns (bool filled, Currency, Currency, uint256 total0, uint256 total1, uint128 liquidityTotal)
    {
        return hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(id));
    }

    function _liquidityOf(uint232 id, address actor) private view returns (uint256) {
        return hook.getOrderLiquidity(OrderIdLibrary.OrderId.wrap(id), actor);
    }

    /// @dev Thin unwrap over `hook.getOrderId`. Returns zero (`ORDER_ID_DEFAULT`) when no order is
    /// active at the key, so callers must treat zero as absence.
    function _orderIdAt(int24 tickLower, bool zeroForOne) private view returns (uint232) {
        return OrderIdLibrary.OrderId.unwrap(hook.getOrderId(key, tickLower, zeroForOne));
    }

    function _balanceOf(Currency currency, address who) private view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(currency)).balanceOf(who);
    }

    function _currentTick() private view returns (int24) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }
}
