// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {LimitOrderHookMock} from "src/mocks/general/LimitOrderHookMock.sol";
import {HookTest} from "test/utils/HookTest.sol";
import {LimitOrderHookHandler} from "../../handlers/LimitOrderHook/LimitOrderHookHandler.sol";

/// @dev Campaign for {LimitOrderHook} invariants. See `LimitOrderHook.invariants.md`.
contract LimitOrderHookInvariantsTest is HookTest {
    using StateLibrary for IPoolManager;

    LimitOrderHookMock hook;
    LimitOrderHookHandler handler;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    /// @dev Fuzzer bounds for `liquidity`.
    uint256 constant LIQUIDITY_MIN_BOUND = 1;
    uint256 constant LIQUIDITY_MAX_BOUND = 1e21;

    /// @dev Fuzzer bounds for `amount`.
    uint256 constant AMOUNT_MIN_BOUND = 1;
    uint256 constant AMOUNT_MAX_BOUND = 1e21;

    /// @dev Slack for `mulDiv` truncation: at most a wei per credit or payout, so it grows with the
    /// call count, not the amounts.
    uint256 constant ACCUMULATED_ROUNDING_TOLERANCE = 1e4;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LimitOrderHookMock(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));
        deployCodeTo(
            "src/mocks/general/LimitOrderHookMock.sol:LimitOrderHookMock", abi.encode(address(manager)), address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;

        int24[] memory ticks = new int24[](4);
        ticks[0] = -2 * key.tickSpacing;
        ticks[1] = -key.tickSpacing;
        ticks[2] = key.tickSpacing;
        ticks[3] = 2 * key.tickSpacing;

        handler = new LimitOrderHookHandler(
            hook,
            manager,
            swapRouter,
            key,
            actors,
            ticks,
            LIQUIDITY_MIN_BOUND,
            LIQUIDITY_MAX_BOUND,
            AMOUNT_MIN_BOUND,
            AMOUNT_MAX_BOUND
        );

        for (uint256 i; i < actors.length; ++i) {
            _fund(actors[i]);
        }
        _fund(address(handler));

        targetContract(address(handler));
    }

    function _fund(address who) private {
        IERC20Minimal(Currency.unwrap(currency0)).transfer(who, 1e28);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(who, 1e28);

        vm.startPrank(who);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev INV-L-01: an order's total liquidity equals the sum of its owners' liquidity.
    function invariant_L01_orderLiquidityEqualsSumOfOwnerShares() public view {
        uint232[] memory orderIds = handler.orderIds();
        address[] memory actors = handler.actors();

        for (uint256 i; i < orderIds.length; ++i) {
            OrderIdLibrary.OrderId id = OrderIdLibrary.OrderId.wrap(orderIds[i]);

            (,,,,,,, uint128 liquidityTotal) = hook.getOrderInfo(id);

            uint256 ownedLiquidity;
            for (uint256 a; a < actors.length; ++a) {
                ownedLiquidity += hook.getUserInfo(id, actors[a]).liquidity;
            }

            assertEq(uint256(liquidityTotal), ownedLiquidity, "INV-L-01: liquidityTotal is not the sum of owner shares");
        }
    }

    /// @dev INV-L-02: an order is filled as soon as the price crosses its tick. Measured against the
    /// tick the pool stores, not the one the hook derives from the price, so the two cannot agree by
    /// sharing a derivation.
    function invariant_L02_noActiveOrderSurvivesThePriceCrossingIt() public view {
        int24 tickLowerNow = handler.storedTickLower();
        int24[] memory ticks = handler.ticks();

        for (uint256 i; i < ticks.length; ++i) {
            _assertActiveOrderIsBehindThePrice(ticks[i], true, tickLowerNow);
            _assertActiveOrderIsBehindThePrice(ticks[i], false, tickLowerNow);
        }
    }

    /// @dev No-op when no order is active at the key.
    function _assertActiveOrderIsBehindThePrice(int24 tickLower, bool zeroForOne, int24 tickLowerNow) private view {
        if (handler.orderId(tickLower, zeroForOne) == 0) return;

        if (zeroForOne) {
            assertLe(tickLowerNow, tickLower, "INV-L-02: the price rose past a live zeroForOne order");
        } else {
            assertGe(tickLowerNow, tickLower, "INV-L-02: the price fell past a live oneForZero order");
        }
    }

    /// @dev INV-L-03: the recorded tick lower tracks the pool's stored tick. Drift leaves orders in the
    /// gap unfilled.
    function invariant_L03_recordedTickLowerTracksThePoolTick() public view {
        assertEq(
            hook.getTickLowerLast(key.toId()),
            handler.storedTickLower(),
            "INV-L-03: the recorded tick lower does not match the pool's stored tick"
        );
    }

    /// @dev INV-L-04: a live order's pool position holds exactly that order's liquidity.
    function invariant_L04_liveOrderOwnsItsPositionAlone() public view {
        int24[] memory tickList = handler.ticks();

        for (uint256 i; i < tickList.length; ++i) {
            _assertPositionHoldsOnlyTheOrder(tickList[i], true);
            _assertPositionHoldsOnlyTheOrder(tickList[i], false);
        }
    }

    /// @dev The expected position salt per direction, stated here rather than read from the hook.
    function positionSalt(bool zeroForOne) internal pure returns (bytes32) {
        return zeroForOne ? bytes32(uint256(1)) : bytes32(0);
    }

    /// @dev No-op when no order is live at the key.
    function _assertPositionHoldsOnlyTheOrder(int24 tickLower, bool zeroForOne) private view {
        uint232 id = handler.orderId(tickLower, zeroForOne);
        if (id == 0) return;

        (,,,,,,, uint128 liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(id));

        uint128 positionLiquidity = manager.getPositionLiquidity(
            key.toId(),
            Position.calculatePositionKey(
                address(hook), tickLower, tickLower + key.tickSpacing, positionSalt(zeroForOne)
            )
        );

        assertEq(positionLiquidity, liquidityTotal, "INV-L-04: a live order does not hold its pool position alone");
    }

    /// @dev INV-F-01: a fully withdrawn order holds no liquidity.
    function invariant_F01_fullyWithdrawnOrderHoldsNoLiquidity() public view {
        uint232[] memory ids = handler.orderIds();

        for (uint256 i; i < ids.length; ++i) {
            if (!handler.ghost_wasFullyWithdrawn(ids[i])) continue;

            (,,,,,,, uint128 liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(ids[i]));

            assertEq(liquidityTotal, 0, "INV-F-01: fully withdrawn order still records liquidity");
        }
    }

    /// @dev INV-F-02: a fully withdrawn order has no remaining principal.
    function invariant_F02_fullyWithdrawnOrderHasNoRemainingPrincipal() public view {
        uint232[] memory ids = handler.orderIds();

        for (uint256 i; i < ids.length; ++i) {
            if (!handler.ghost_wasFullyWithdrawn(ids[i])) continue;

            (,,, uint256 principal0, uint256 principal1,,,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(ids[i]));

            assertEq(principal0, 0, "INV-F-02: fully withdrawn order records currency0 principal");
            assertEq(principal1, 0, "INV-F-02: fully withdrawn order records currency1 principal");
        }
    }

    /// @dev INV-F-03: a filled order cannot be cancelled, since `cancelOrder` only reaches an order
    /// through a live key.
    function invariant_F03_noLiveKeyResolvesToAFilledOrder() public view {
        int24[] memory ticks = handler.ticks();

        for (uint256 i; i < ticks.length; ++i) {
            _assertActiveOrderIsNotFilled(ticks[i], true);
            _assertActiveOrderIsNotFilled(ticks[i], false);
        }
    }

    /// @dev No-op when no order is active at the key.
    function _assertActiveOrderIsNotFilled(int24 tickLower, bool zeroForOne) private view {
        uint232 id = handler.orderId(tickLower, zeroForOne);
        if (id == 0) return;

        (bool filled,,,,,,,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(id));
        assertFalse(filled, "INV-F-03: a live key resolves to a filled order");
    }

    /// @dev INV-S-01: the hook's claims cover every order's recorded principal plus the fees owed to its owners.
    function invariant_S01_hookHoldsEveryAmountItOwes() public view {
        uint232[] memory orderIds = handler.orderIds();
        address[] memory actors = handler.actors();

        uint256 owed0;
        uint256 owed1;

        for (uint256 i; i < orderIds.length; ++i) {
            (,,, uint256 principal0, uint256 principal1,,,) =
                hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(orderIds[i]));

            owed0 += principal0;
            owed1 += principal1;

            for (uint256 a; a < actors.length; ++a) {
                (uint256 fees0, uint256 fees1) = handler.feesOwed(orderIds[i], actors[a]);
                owed0 += fees0;
                owed1 += fees1;
            }
        }

        uint256 claims0 = handler.claimsOf(currency0, address(hook));
        uint256 claims1 = handler.claimsOf(currency1, address(hook));

        assertGe(claims0, owed0, "INV-S-01: currency0 claims fall short of what the hook owes");
        assertGe(claims1, owed1, "INV-S-01: currency1 claims fall short of what the hook owes");

        assertApproxEqAbs(
            claims0,
            owed0,
            ACCUMULATED_ROUNDING_TOLERANCE,
            "INV-S-01: currency0 claims exceeds the rounding tolerance of what the hook owes"
        );
        assertApproxEqAbs(
            claims1,
            owed1,
            ACCUMULATED_ROUNDING_TOLERANCE,
            "INV-S-01: currency1 claims exceeds the rounding tolerance of what the hook owes"
        );
    }

    /// @dev INV-C-01: an order id is reset only after its last canceller. Scoped to unfilled orders,
    /// since a fill retires the key while the liquidity is still recorded.
    function invariant_C01_orderIdIsResetOnlyAfterTheLastCanceller() public view {
        uint232[] memory ids = handler.orderIds();

        for (uint256 i; i < ids.length; ++i) {
            (bool filled,,,,,,,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(ids[i]));

            if (handler.ghost_wasFullyCancelled(ids[i])) {
                assertTrue(handler.orderIdWasRemoved(ids[i]), "INV-C-01: fully cancelled order id was not reset");
            }
            if (!filled && !handler.ghost_wasFullyCancelled(ids[i])) {
                assertFalse(handler.orderIdWasRemoved(ids[i]), "INV-C-01: partially cancelled order id was reset");
            }
        }
    }

    /// @dev INV-C-03: a fully cancelled order holds no liquidity.
    function invariant_C03_fullyCancelledOrderHoldsNoLiquidity() public view {
        uint232[] memory ids = handler.orderIds();

        for (uint256 i; i < ids.length; ++i) {
            if (!handler.ghost_wasFullyCancelled(ids[i])) continue;

            (,,,,,,, uint128 liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(ids[i]));

            assertEq(liquidityTotal, 0, "INV-C-03: fully cancelled order still records liquidity");
        }
    }

    /// @dev INV-C-04: a fully cancelled order holds no principal, since only a fill credits principal.
    function invariant_C04_fullyCancelledOrderHoldsNoPrincipal() public view {
        uint232[] memory ids = handler.orderIds();

        for (uint256 i; i < ids.length; ++i) {
            if (!handler.ghost_wasFullyCancelled(ids[i])) continue;

            (,,, uint256 principal0, uint256 principal1,,,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(ids[i]));

            assertEq(principal0, 0, "INV-C-04: fully cancelled order records currency0 principal");
            assertEq(principal1, 0, "INV-C-04: fully cancelled order records currency1 principal");
        }
    }

    /// @dev Per-sequence coverage report: actions that reached the hook and the states the
    /// invariants quantify over.
    function afterInvariant() public view {
        console.log("--- STATS ---");
        _reportActions();
        _reportOrders();
    }

    function _reportActions() private view {
        uint256 placeOrder = handler.calls("placeOrder");
        uint256 cancelOrder = handler.calls("cancelOrder");
        uint256 withdraw = handler.calls("withdraw");
        uint256 swapTo = handler.calls("swapTo");
        uint256 swapRoundTrip = handler.calls("swapRoundTrip");

        console.log("--- actions ---");
        console.log("placeOrder      ", placeOrder);
        console.log("cancelOrder     ", cancelOrder);
        console.log("withdraw        ", withdraw);
        console.log("swapTo          ", swapTo);
        console.log("swapRoundTrip   ", swapRoundTrip);
        console.log("total           ", placeOrder + cancelOrder + withdraw + swapTo + swapRoundTrip);

        assertGt(placeOrder, 0, "placeOrder was not exercised");
        assertGt(cancelOrder, 0, "cancelOrder was not exercised");
        assertGt(withdraw, 0, "withdraw was not exercised");
        assertGt(swapTo, 0, "swapTo was not exercised");
        assertGt(swapRoundTrip, 0, "swapRoundTrip was not exercised");
    }

    function _reportOrders() private view {
        uint256 orderCount = handler.orderIdCount();
        uint256 fillCount = handler.ghost_fillCount();
        uint256 fullyCancelledCount = handler.ghost_fullyCancelCount();
        uint256 fullyWithdrawnCount = handler.ghost_fullyWithdrawnCount();
        (uint256 multiWithdrawer, uint256 multiCanceller) = _multiExitCounts();

        uint256 multiOwnerRatio = handler.ghost_multipleOwnerCount() * 100 / orderCount;
        uint256 multiWithdrawerRatio = multiWithdrawer * 100 / fullyWithdrawnCount;
        uint256 multiCancellerRatio = multiCanceller * 100 / fullyCancelledCount;

        console.log("--- orders ---");
        console.log("created         ", orderCount);
        console.log("open            ", orderCount - fillCount - fullyCancelledCount);
        console.log("filled          ", fillCount);
        console.log("fully withdrawn   ", fullyWithdrawnCount);
        console.log("fully cancelled   ", fullyCancelledCount);
        console.log("had multiple owners", handler.ghost_multipleOwnerCount());
        console.log("multi withdrawer fully withdrawn", multiWithdrawer);
        console.log("multi canceller fully cancelled", multiCanceller);
        console.log("multi owner ratio", multiOwnerRatio, "%");
        console.log("multi withdrawer ratio", multiWithdrawerRatio, "%");
        console.log("multi canceller ratio", multiCancellerRatio, "%");
        console.log("boundary placements", handler.ghost_boundaryPlacements());
        console.log("in-range boundary placements", handler.ghost_inRangeBoundaryPlacements());

        assertGt(orderCount, 0, "no order was created");
        assertGt(fillCount, 0, "no order was filled");
        assertGt(fullyWithdrawnCount, 0, "no order was fully withdrawn");
        assertGt(fullyCancelledCount, 0, "no order was fully cancelled");
        assertGt(handler.ghost_boundaryPlacements(), 0, "no order was placed at the price boundary");
    }

    /// @dev Orders whose exit was split across more than one actor.
    function _multiExitCounts() private view returns (uint256 multiWithdrawer, uint256 multiCanceller) {
        uint232[] memory ids = handler.orderIds();

        for (uint256 i; i < ids.length; ++i) {
            if (handler.ghost_wasFullyWithdrawn(ids[i]) && handler.withdrawersOf(ids[i]).length > 1) {
                ++multiWithdrawer;
            }
            if (handler.ghost_wasFullyCancelled(ids[i]) && handler.cancellersOf(ids[i]).length > 1) {
                ++multiCanceller;
            }
        }
    }
}
