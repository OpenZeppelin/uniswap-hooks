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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LimitOrderHook, OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {LimitOrderHookMock} from "src/mocks/general/LimitOrderHookMock.sol";
import {BaseHandler} from "../BaseHandler.sol";
import {OrderIdSet, LibOrderIdSet, OrderKey} from "./helpers/OrderIdSet.sol";
import {AddressSet, LibAddressSet} from "../../helpers/AddressSet.sol";

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
    using LibAddressSet for AddressSet;

    LimitOrderHookMock public hook;

    /// @dev Scale of the hook's per-liquidity fee accumulators.
    uint256 public constant Q128 = 1 << 128;

    uint256 public immutable LIQUIDITY_MIN_BOUND;
    uint256 public immutable LIQUIDITY_MAX_BOUND;
    uint256 public immutable AMOUNT_MIN_BOUND;
    uint256 public immutable AMOUNT_MAX_BOUND;

    /// @dev Every order id the handler has caused to be created, with the key it was created for.
    OrderIdSet internal ghost_orderIds;

    /// @dev Sets of actors that placed into, cancelled from, and withdrew from each order.
    mapping(uint232 orderId => AddressSet) internal ghost_placers;
    mapping(uint232 orderId => AddressSet) internal ghost_cancellers;
    mapping(uint232 orderId => AddressSet) internal ghost_withdrawers;

    /// @dev Actors currently holding a share of each order, and how many.
    mapping(uint232 orderId => mapping(address owner => bool)) internal ghost_isOwner;
    mapping(uint232 orderId => uint256) public ghost_activeOwners;

    /// @dev Sticky record of every order observed filled, and how many.
    mapping(uint232 orderId => bool) public ghost_wasFilled;
    uint256 public ghost_fillCount;

    /// @dev Sticky record of every fully cancelled order, and how many.
    mapping(uint232 orderId => bool) public ghost_wasFullyCancelled;
    uint256 public ghost_cancelCount;

    /// @dev Sticky record of every filled order every owner has withdrawn from, and how many.
    mapping(uint232 orderId => bool) public ghost_wasFullyWithdrawn;
    uint256 public ghost_fullyWithdrawnCount;

    /// @dev Sticky record of every order that ever held multiple owners at once, and how many.
    mapping(uint232 orderId => bool) public ghost_hadMultipleOwners;
    uint256 public ghost_multipleOwnerCount;

    /// @dev Sync the sticky order state ghosts after each action.
    modifier ghost_syncOrderState() {
        _;
        _ghost_syncOrderState();
    }

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
    ) {
        hook = hook_;
        manager = manager_;
        swapRouter = swapRouter_;
        key = key_;
        poolId = key_.toId();

        _createActors(actors_);
        _createTicks(ticks_);

        LIQUIDITY_MIN_BOUND = liquidityMinBound_;
        LIQUIDITY_MAX_BOUND = liquidityMaxBound_;
        AMOUNT_MIN_BOUND = amountMinBound_;
        AMOUNT_MAX_BOUND = amountMaxBound_;

        IERC20Minimal(Currency.unwrap(key_.currency0)).approve(address(swapRouter_), type(uint256).max);
        IERC20Minimal(Currency.unwrap(key_.currency1)).approve(address(swapRouter_), type(uint256).max);
    }

    // ------------------ FUZZABLE SURFACE ------------------ //

    function placeOrder(uint256 actorSeed, uint256 tickSeed, bool zeroForOne, uint256 liquiditySeed)
        external
        ghost_syncOrderState
        recordCall("placeOrder")
    {
        int24 tickLower = _tickFromSeed(tickSeed);

        // The hook reverts if the order is not placeable.
        vm.assume(_placeable(tickLower, zeroForOne));

        address actor = _actorFromSeed(actorSeed);
        uint128 liquidity = uint128(bound(liquiditySeed, LIQUIDITY_MIN_BOUND, LIQUIDITY_MAX_BOUND));

        vm.prank(actor);
        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        uint232 id = _orderId(tickLower, zeroForOne);
        ghost_orderIds.add(id, OrderKey(tickLower, zeroForOne));
        ghost_placers[id].add(actor);
        _ghost_joinOrder(id, actor);
    }

    /// @dev Cancelling an order removes liquidity from the order
    /// and collects accrued fees from swaps into the order
    function cancelOrder(uint256 actorSeed, uint256 tickSeed, bool zeroForOne)
        external
        ghost_syncOrderState
        recordCall("cancelOrder")
    {
        int24 tickLower = _tickFromSeed(tickSeed);

        uint232 id = _orderId(tickLower, zeroForOne);
        vm.assume(id != 0);

        (bool filled,,,) = _orderInfo(id);
        vm.assume(!filled);

        address actor = _ownerFromSeed(id, actorSeed);
        vm.assume(actor != address(0));

        vm.prank(actor);
        hook.cancelOrder(key, tickLower, zeroForOne, actor);

        ghost_cancellers[id].add(actor);
        _ghost_exitOrder(id, actor);
    }

    /// @dev Withdrawing an order removes liquidity from the order
    /// and collects accrued fees from swaps into the order
    function withdraw(uint256 actorSeed, uint256 idSeed) external ghost_syncOrderState recordCall("withdraw") {
        vm.assume(ghost_orderIds.count() > 0);

        uint232 id = ghost_orderIds.rand(idSeed);

        (bool filled,,,) = _orderInfo(id);
        vm.assume(filled);

        address actor = _ownerFromSeed(id, actorSeed);
        vm.assume(actor != address(0));

        vm.prank(actor);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(id), actor);

        ghost_withdrawers[id].add(actor);
        _ghost_exitOrder(id, actor);
    }

    /// @dev Move the price to an arbitrary candidate tick, crossing whatever lies between.
    /// Fills every order the price moves past.
    function swapTo(uint256 tickSeed, uint256 amountSeed) external ghost_syncOrderState recordCall("swapTo") {
        int24 target = _tickFromSeed(tickSeed);
        int24 current = _currentTick();
        vm.assume(target != current);

        _swap(target < current, bound(amountSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND), target);
    }

    /**
     * @dev Price excursion into a tick range and back out, without crossing it.
     *
     * Fees accrue to any order at that tick and no order fills. Modelled as one action because a
     * round trip is a single market event, and because splitting it makes the fee-accrual state two
     * rare steps instead of one, which the fuzzer reaches far less often.
     */
    function swapRoundTrip(uint256 tickSeed, uint256 amountSeed)
        external
        ghost_syncOrderState
        recordCall("swapRoundTrip")
    {
        int24 tickLower = _tickFromSeed(tickSeed);
        int24 current = _currentTick();

        uint256 amount = bound(amountSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND);

        // an excursion only exists if the price starts outside the range
        vm.assume(current < tickLower || current >= tickLower + key.tickSpacing);

        if (current < tickLower) {
            _swap(false, amount, tickLower + key.tickSpacing / 2);
            _swap(true, amount, current);
        } else {
            _swap(true, amount, tickLower + key.tickSpacing / 2);
            _swap(false, amount, current);
        }
    }

    // ------------------ VIEWS ------------------ //

    /// @dev Every order id the handler has created, live or not.
    function orderIds() public view returns (uint232[] memory) {
        return ghost_orderIds.ids;
    }

    /// @dev Number of order ids the handler has created.
    function orderIdCount() public view returns (uint256) {
        return ghost_orderIds.count();
    }

    /// @dev The tick and direction `id` was created for.
    function orderKeyOf(uint232 id) public view returns (OrderKey memory) {
        return ghost_orderIds.keyOf(id);
    }

    /// @dev Order id registered for `tickLower` and `zeroForOne`, or zero when no order is active there.
    /// A non-zero result means the order is live, since the hook retires the key on fill and on the last cancel.
    function orderId(int24 tickLower, bool zeroForOne) public view returns (uint232) {
        return _orderId(tickLower, zeroForOne);
    }

    /// @dev Whether the key `id` was created for has stopped resolving to it.
    function orderIdWasRemoved(uint232 id) public view returns (bool) {
        return _orderIdWasRemoved(id);
    }

    /// @dev Actors that placed into `id`.
    function placersOf(uint232 id) public view returns (address[] memory) {
        return ghost_placers[id].addrs;
    }

    /// @dev Actors that cancelled their share of `id`.
    function cancellersOf(uint232 id) public view returns (address[] memory) {
        return ghost_cancellers[id].addrs;
    }

    /// @dev Actors that withdrew their share of `id`.
    function withdrawersOf(uint232 id) public view returns (address[] memory) {
        return ghost_withdrawers[id].addrs;
    }

    /// @dev Fees `actor` has accrued in order `id` and not yet collected: the growth of the order's
    /// per-liquidity accumulators since the actor's checkpoint, scaled by their liquidity.
    function feesOwed(uint232 id, address actor) public view returns (uint256 owed0, uint256 owed1) {
        LimitOrderHook.UserInfo memory userInfo = hook.getUserInfo(OrderIdLibrary.OrderId.wrap(id), actor);
        if (userInfo.liquidity == 0) return (0, 0);

        (,,,,, uint256 acc0, uint256 acc1,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(id));

        owed0 = Math.mulDiv(acc0 - userInfo.feeCheckpoint0X128, userInfo.liquidity, Q128);
        owed1 = Math.mulDiv(acc1 - userInfo.feeCheckpoint1X128, userInfo.liquidity, Q128);
    }

    // ------------------ INTERNALS ------------------ //

    /**
     * @dev Refresh the sticky lifecycle flags for every known order.
     *
     * Called after each action rather than inside it, because a swap can fill orders at several ticks
     * at once and the affected ids are not known up front.
     *
     * The exit flags are derived from the participant sets and never from `liquidityTotal` or
     * `principalCredited`, which is what lets the campaign assert those two against them. Comparing
     * counts rather than members is sound only because an actor needs liquidity to exit and liquidity
     * only comes from placing, so the exit sets are subsets of the placers.
     */
    function _ghost_syncOrderState() private {
        for (uint256 i; i < ghost_orderIds.count(); ++i) {
            uint232 id = ghost_orderIds.ids[i];
            (bool filled,,,) = _orderInfo(id);

            // Mark the order as filled if it was not already.
            if (filled && !ghost_wasFilled[id]) {
                ghost_wasFilled[id] = true;
                ++ghost_fillCount;
            }

            // No owner is left, so every one of them exited.
            bool everyOwnerExited = ghost_activeOwners[id] == 0;

            if (everyOwnerExited && !filled && !ghost_wasFullyCancelled[id]) {
                ghost_wasFullyCancelled[id] = true;
                ++ghost_cancelCount;
            }

            if (everyOwnerExited && filled && !ghost_wasFullyWithdrawn[id]) {
                ghost_wasFullyWithdrawn[id] = true;
                ++ghost_fullyWithdrawnCount;
            }
        }
    }

    /// @dev Record that `actor` has joined `id` via `placeOrder`.
    function _ghost_joinOrder(uint232 id, address actor) private {
        if (ghost_isOwner[id][actor]) return;

        ghost_isOwner[id][actor] = true;
        ++ghost_activeOwners[id];

        if (ghost_activeOwners[id] > 1 && !ghost_hadMultipleOwners[id]) {
            ghost_hadMultipleOwners[id] = true;
            ++ghost_multipleOwnerCount;
        }
    }

    /// @dev Record that `actor` has left `id` via `cancelOrder` or `withdraw`.
    function _ghost_exitOrder(uint232 id, address actor) private {
        if (ghost_isOwner[id][actor]) {
            ghost_isOwner[id][actor] = false;
            --ghost_activeOwners[id];
        }
    }

    /// @dev Whether the key `id` was created for has stopped resolving to it. A later `placeOrder`
    /// at the same key allocates a fresh id, which leaves this true.
    /// An order is retired when it is filled or cancelled.
    function _orderIdWasRemoved(uint232 id) private view returns (bool) {
        OrderKey memory orderKey = ghost_orderIds.keyOf(id);
        return _orderId(orderKey.tickLower, orderKey.zeroForOne) != id;
    }

    /**
     * @dev An actor holding liquidity in `id`, or the zero address when none does.
     *
     * Rotates the actor set from `seed` rather than indexing into it, because indexing wastes most
     * generated calls: an order typically has one or two owners out of three actors, so a random pick
     * misses more often than it hits and the exit paths stay under-exercised.
     */
    function _ownerFromSeed(uint232 id, uint256 seed) private view returns (address) {
        uint256 count = _actors.addrs.length;
        uint256 offset = seed % count;

        for (uint256 i; i < count; ++i) {
            address actor = _actors.addrs[(offset + i) % count];
            if (_liquidityOf(id, actor) > 0) return actor;
        }

        return address(0);
    }

    /// @dev Whether `placeOrder` accepts this key at the current price. A `zeroForOne` order sells
    /// currency0, so its range must sit strictly above the price; the reverse sells currency1 and
    /// its range must sit at or below it.
    function _placeable(int24 tickLower, bool zeroForOne) private view returns (bool) {
        int24 current = _currentTick();
        return zeroForOne ? current < tickLower : current >= tickLower + key.tickSpacing;
    }

    /// @dev Thin unwrap over `hook.getOrderInfo`. `principal_c` is the principal the order still holds,
    /// credited by the fill and drawn down by each withdrawal.
    function _orderInfo(uint232 id)
        private
        view
        returns (bool filled, uint256 principal0, uint256 principal1, uint128 liquidityTotal)
    {
        (filled,,, principal0, principal1,,, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(id));
    }

    /// @dev Liquidity `actor` owns in order `id`.
    function _liquidityOf(uint232 id, address actor) private view returns (uint256) {
        return hook.getUserInfo(OrderIdLibrary.OrderId.wrap(id), actor).liquidity;
    }

    /// @dev Thin unwrap over `hook.getOrderId`. Returns zero (`ORDER_ID_DEFAULT`) when no order is
    /// active at the key, so callers must treat zero as absence.
    function _orderId(int24 tickLower, bool zeroForOne) private view returns (uint232) {
        return OrderIdLibrary.OrderId.unwrap(hook.getOrderId(key, tickLower, zeroForOne));
    }
}
