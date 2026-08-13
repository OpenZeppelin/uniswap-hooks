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
 * Fuzzable surface:
 * - `placeOrder`
 * - `cancelOrder`
 * - `withdraw`
 * - `swapTo`
 * - `swapRoundTrip`
 */
contract LimitOrderHookHandler is BaseHandler {
    using StateLibrary for IPoolManager;
    using LibOrderIdSet for OrderIdSet;
    using LibAddressSet for AddressSet;

    LimitOrderHookMock public hook;

    /// @dev Scale of the hook's per-liquidity fee accumulators.
    uint256 public constant Q128 = 1 << 128;

    /// @dev Fuzzer bounds for `liquidity`.
    uint256 public immutable LIQUIDITY_MIN_BOUND;
    uint256 public immutable LIQUIDITY_MAX_BOUND;
    /// @dev Fuzzer bounds for `amount`.
    uint256 public immutable AMOUNT_MIN_BOUND;
    uint256 public immutable AMOUNT_MAX_BOUND;

    /// @dev Target ratio of multi-owner orders.
    uint256 public immutable MULTI_OWNER_TARGET_RATIO = 80;

    /// @dev Every order id the handler has caused to be created, with its key.
    OrderIdSet internal ghost_orderIds;

    /// @dev Actors that placed into, cancelled from, and withdrew from each order.
    mapping(uint232 orderId => AddressSet) internal ghost_placers;
    mapping(uint232 orderId => AddressSet) internal ghost_cancellers;
    mapping(uint232 orderId => AddressSet) internal ghost_withdrawers;

    /// @dev Actors currently holding a share of each order, and how many.
    mapping(uint232 orderId => mapping(address owner => bool)) internal ghost_isOwner;
    mapping(uint232 orderId => uint256) public ghost_activeOwners;

    /// @dev Sticky record of every order observed filled.
    mapping(uint232 orderId => bool) public ghost_wasFilled;
    uint256 public ghost_fillCount;

    /// @dev Sticky record of every fully cancelled order.
    mapping(uint232 orderId => bool) public ghost_wasFullyCancelled;
    uint256 public ghost_fullyCancelCount;

    /// @dev Sticky record of every filled order every owner has withdrawn from.
    mapping(uint232 orderId => bool) public ghost_wasFullyWithdrawn;
    uint256 public ghost_fullyWithdrawnCount;

    /// @dev Sticky record of every order that ever held multiple owners at once.
    mapping(uint232 orderId => bool) public ghost_hadMultipleOwners;
    uint256 public ghost_multipleOwnerCount;

    /// @dev Entitlement per (order, placer) captured before the current action.
    mapping(uint232 orderId => mapping(address owner => uint256 entitlement0)) public ghost_entitlement0;
    mapping(uint232 orderId => mapping(address owner => uint256 entitlement1)) public ghost_entitlement1;

    /// @dev Actor exempt from the entitlement monotonicity assertion, set by the action before it
    /// calls the hook.
    address internal _entitlementExempt;

    /// @dev Sync the sticky order state ghosts after each action.
    modifier ghost_syncOrderState() {
        _;
        _ghost_syncOrderState();
    }

    /// @dev INV-S-02: an action never reduces the entitlement of an owner that did not perform it.
    /// The performing actor is exempt: exits collect their entitlement, and a top-up carries a wei
    /// of checkpoint truncation.
    modifier assertMonotonicEntitlements() {
        _snapshotEntitlements();
        _;
        _assertEntitlementsMonotonic(_entitlementExempt);
        _entitlementExempt = address(0);
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

    /// @dev Places a new order or joins an existing live order.
    function placeOrder(
        uint256 actorSeed,
        uint256 tickSeed,
        bool zeroForOne,
        uint256 liquiditySeed,
        uint256 orderIdSeed
    ) external assertMonotonicEntitlements ghost_syncOrderState recordCall("placeOrder") {
        uint256 multiOwnerRatio =
            ghost_orderIds.count() > 0 ? ghost_multipleOwnerCount * 100 / ghost_orderIds.count() : 0;

        // Below the multi-owner target, bias toward joining an already existing live order.
        uint232 liveId = multiOwnerRatio < MULTI_OWNER_TARGET_RATIO ? _liveOrderFromSeed(orderIdSeed) : 0;

        OrderKey memory orderKey =
            liveId != 0 ? ghost_orderIds.keyOf(liveId) : OrderKey(_tickFromSeed(tickSeed), zeroForOne);

        vm.assume(_placeable(orderKey.tickLower, orderKey.zeroForOne));

        address actor = _actorFromSeed(actorSeed);
        uint128 liquidity = uint128(bound(liquiditySeed, LIQUIDITY_MIN_BOUND, LIQUIDITY_MAX_BOUND));

        _entitlementExempt = actor;
        vm.prank(actor);
        hook.placeOrder(key, orderKey.tickLower, orderKey.zeroForOne, liquidity);

        uint232 id = _orderId(orderKey.tickLower, orderKey.zeroForOne);
        ghost_orderIds.add(id, orderKey);

        ghost_placers[id].add(actor);
        _ghost_joinOrder(id, actor);
    }

    /// @dev Removes the actor's liquidity and collects their accrued fees.
    function cancelOrder(uint256 actorSeed, uint256 idSeed)
        external
        assertMonotonicEntitlements
        ghost_syncOrderState
        recordCall("cancelOrder")
    {
        uint232 id = _liveOrderFromSeed(idSeed);
        vm.assume(id != 0);

        address actor = _ownerFromSeed(id, actorSeed);
        vm.assume(actor != address(0));

        OrderKey memory orderKey = ghost_orderIds.keyOf(id);

        _entitlementExempt = actor;
        vm.prank(actor);
        hook.cancelOrder(key, orderKey.tickLower, orderKey.zeroForOne, actor);

        ghost_cancellers[id].add(actor);
        _ghost_exitOrder(id, actor);
    }

    /// @dev Collects the actor's share of a filled order: principal plus accrued fees.
    function withdraw(uint256 actorSeed, uint256 idSeed)
        external
        assertMonotonicEntitlements
        ghost_syncOrderState
        recordCall("withdraw")
    {
        uint232 id = _filledOrderFromSeed(idSeed);
        vm.assume(id != 0);

        address actor = _ownerFromSeed(id, actorSeed);
        vm.assume(actor != address(0));

        _entitlementExempt = actor;
        vm.prank(actor);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(id), actor);

        ghost_withdrawers[id].add(actor);
        _ghost_exitOrder(id, actor);
    }

    /// @dev Move the price toward a candidate tick, filling every order it crosses.
    function swapTo(uint256 tickSeed, uint256 amountSeed)
        external
        assertMonotonicEntitlements
        ghost_syncOrderState
        recordCall("swapTo")
    {
        int24 target = _tickFromSeed(tickSeed);
        int24 current = _currentTick();
        vm.assume(target != current);

        _swap(target < current, bound(amountSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND), target);
    }

    /// @dev Price excursion into a tick range and back out, without crossing it: fees accrue and no
    /// order fills. One action because the fuzzer rarely composes it from two.
    function swapRoundTrip(uint256 tickSeed, uint256 amountSeed)
        external
        assertMonotonicEntitlements
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

    /// @dev Order id active at the key, or zero. Non-zero implies live, since the hook retires the
    /// key on fill and on the last cancel.
    function orderId(int24 tickLower, bool zeroForOne) public view returns (uint232) {
        return _orderId(tickLower, zeroForOne);
    }

    /// @dev Whether the key `id` was created for has stopped resolving to it.
    /// An order is removed after it is filled or its last liquidity is cancelled.
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

    /// @dev Uncollected fees of `actor` in `id`: accumulator growth since their checkpoint, scaled
    /// by their liquidity.
    function feesOwed(uint232 id, address actor) public view returns (uint256 owed0, uint256 owed1) {
        LimitOrderHook.UserInfo memory userInfo = hook.getUserInfo(OrderIdLibrary.OrderId.wrap(id), actor);
        if (userInfo.liquidity == 0) return (0, 0);

        (,,,,, uint256 acc0, uint256 acc1,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(id));

        owed0 = Math.mulDiv(acc0 - userInfo.feeCheckpoint0X128, userInfo.liquidity, Q128);
        owed1 = Math.mulDiv(acc1 - userInfo.feeCheckpoint1X128, userInfo.liquidity, Q128);
    }

    /// @dev ``actor``'s share of the principal still recorded in `id`, pro-rata by liquidity.
    function principalOwed(uint232 id, address actor) public view returns (uint256 principal0, uint256 principal1) {
        uint256 liquidity = _liquidityOf(id, actor);
        if (liquidity == 0) return (0, 0);

        (, uint256 principalCredited0, uint256 principalCredited1, uint128 liquidityTotal) = _orderInfo(id);
        principal0 = Math.mulDiv(principalCredited0, liquidity, liquidityTotal);
        principal1 = Math.mulDiv(principalCredited1, liquidity, liquidityTotal);
    }

    /// @dev Everything the hook owes `actor` in `id`: fees plus principal share. Recomputed from raw
    /// hook state rather than the hook's own views, so a broken view cannot vouch for itself.
    function entitlementOf(uint232 id, address actor) public view returns (uint256 owed0, uint256 owed1) {
        (uint256 fees0, uint256 fees1) = feesOwed(id, actor);
        (uint256 principal0, uint256 principal1) = principalOwed(id, actor);

        return (fees0 + principal0, fees1 + principal1);
    }

    // ------------------ INTERNALS ------------------ //

    /**
     * @dev Refresh the sticky lifecycle flags for every known order. Runs after each action because
     * a swap can fill orders at several ticks at once.
     *
     * The exit flags derive from the owner count and never from `liquidityTotal` or
     * `principalCredited`, which is what lets the campaign assert those two against them.
     */
    function _ghost_syncOrderState() private {
        for (uint256 i; i < ghost_orderIds.count(); ++i) {
            uint232 id = ghost_orderIds.ids[i];
            (bool filled,,,) = _orderInfo(id);

            if (filled && !ghost_wasFilled[id]) {
                ghost_wasFilled[id] = true;
                ++ghost_fillCount;
            }

            bool everyOwnerExited = ghost_activeOwners[id] == 0;

            if (everyOwnerExited && !filled && !ghost_wasFullyCancelled[id]) {
                ghost_wasFullyCancelled[id] = true;
                ++ghost_fullyCancelCount;
            }

            if (everyOwnerExited && filled && !ghost_wasFullyWithdrawn[id]) {
                ghost_wasFullyWithdrawn[id] = true;
                ++ghost_fullyWithdrawnCount;
            }
        }
    }

    /// @dev Capture every (order, placer) entitlement before the action.
    function _snapshotEntitlements() private {
        for (uint256 i; i < ghost_orderIds.count(); ++i) {
            uint232 id = ghost_orderIds.ids[i];
            for (uint256 j; j < ghost_placers[id].count(); ++j) {
                address placer = ghost_placers[id].addrs[j];
                (ghost_entitlement0[id][placer], ghost_entitlement1[id][placer]) = entitlementOf(id, placer);
            }
        }
    }

    /// @dev Assert no (order, placer) entitlement fell below its snapshot, except for `exempt`.
    /// Pairs created during the action have no snapshot and pass against zero.
    function _assertEntitlementsMonotonic(address exempt) private view {
        for (uint256 i; i < ghost_orderIds.count(); ++i) {
            uint232 id = ghost_orderIds.ids[i];
            for (uint256 j; j < ghost_placers[id].count(); ++j) {
                address placer = ghost_placers[id].addrs[j];
                if (placer == exempt) continue;

                (uint256 owed0, uint256 owed1) = entitlementOf(id, placer);
                assertGe(
                    owed0,
                    ghost_entitlement0[id][placer],
                    "INV-S-02: an action reduced a non-participant's currency0 entitlement"
                );
                assertGe(
                    owed1,
                    ghost_entitlement1[id][placer],
                    "INV-S-02: an action reduced a non-participant's currency1 entitlement"
                );
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

    /// @dev Whether the key `id` was created for has stopped resolving to it, which happens on fill
    /// and on the last cancel. A later `placeOrder` at the key mints a fresh id, so this stays true.
    function _orderIdWasRemoved(uint232 id) private view returns (bool) {
        OrderKey memory orderKey = ghost_orderIds.keyOf(id);
        return _orderId(orderKey.tickLower, orderKey.zeroForOne) != id;
    }

    /// @dev An actor holding liquidity in `id`, or the zero address when none does. Rotates the
    /// actor set from `seed` rather than indexing it, for an increased chance of hitting a valid owner.
    function _ownerFromSeed(uint232 id, uint256 seed) private view returns (address) {
        uint256 count = _actors.addrs.length;
        uint256 offset = seed % count;

        for (uint256 i; i < count; ++i) {
            address actor = _actors.addrs[(offset + i) % count];
            if (_liquidityOf(id, actor) > 0) return actor;
        }

        return address(0);
    }

    /// @dev A live order id picked from `seed`, or zero when none is live. Rotates the id set for an
    /// increased chance of hitting a valid live order.
    function _liveOrderFromSeed(uint256 seed) private view returns (uint232) {
        uint256 count = ghost_orderIds.count();
        if (count == 0) return 0;

        uint256 offset = seed % count;
        for (uint256 i; i < count; ++i) {
            uint232 id = ghost_orderIds.ids[(offset + i) % count];
            if (!ghost_wasFilled[id] && !ghost_wasFullyCancelled[id]) return id;
        }

        return 0;
    }

    /// @dev A filled order id with shares still to withdraw, picked from `seed`, or zero when none exists. Rotates the id set for an
    /// increased chance of hitting a valid filled order.
    function _filledOrderFromSeed(uint256 seed) private view returns (uint232) {
        uint256 count = ghost_orderIds.count();
        if (count == 0) return 0;

        uint256 offset = seed % count;
        for (uint256 i; i < count; ++i) {
            uint232 id = ghost_orderIds.ids[(offset + i) % count];
            if (ghost_wasFilled[id] && !ghost_wasFullyWithdrawn[id]) return id;
        }

        return 0;
    }

    /// @dev Whether `placeOrder` accepts this key at the current price: a `zeroForOne` order's range
    /// must sit strictly above the price, the reverse at or below it.
    function _placeable(int24 tickLower, bool zeroForOne) private view returns (bool) {
        int24 current = _currentTick();
        return zeroForOne ? current < tickLower : current >= tickLower + key.tickSpacing;
    }

    /// @dev Thin unwrap over `hook.getOrderInfo`. `principal_c` is the principal the order still
    /// holds: credited by the fill, drawn down by each withdrawal.
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

    /// @dev Thin unwrap over `hook.getOrderId`. Zero (`ORDER_ID_DEFAULT`) means no order is active
    /// at the key.
    function _orderId(int24 tickLower, bool zeroForOne) private view returns (uint232) {
        return OrderIdLibrary.OrderId.unwrap(hook.getOrderId(key, tickLower, zeroForOne));
    }
}
