// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// Internal imports
import {BaseHook} from "src/base/BaseHook.sol";
import {LimitOrderHook, OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {LimitOrderHookMock} from "../../src/mocks/general/LimitOrderHookMock.sol";
import {HookTest} from "../utils/HookTest.sol";

contract LimitOrderHookTest is HookTest {
    using StateLibrary for IPoolManager;
    using OrderIdLibrary for OrderIdLibrary.OrderId;

    LimitOrderHookMock hook;
    PoolKey noHookKey;

    address user = makeAddr("user");
    address swapper = makeAddr("swapper");
    address attacker = makeAddr("attacker");

    int24 tickSpacing;

    /// @dev Salts to keep each owner's liquidity in a separate position on the hookless pool.
    bytes32 constant SALT_THIS = bytes32(uint256(1));
    bytes32 constant SALT_USER = bytes32(uint256(2));

    /// @dev Tolerance for the truncation dust of pro-rata splits.
    uint256 constant DUST = 2;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LimitOrderHookMock(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));

        deployCodeTo(
            "src/mocks/general/LimitOrderHookMock.sol:LimitOrderHookMock", abi.encode(address(manager)), address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        (noHookKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        tickSpacing = key.tickSpacing;

        address[3] memory holders = [user, swapper, attacker];
        for (uint256 i = 0; i < holders.length; i++) {
            IERC20Minimal(Currency.unwrap(currency0)).transfer(holders[i], 1e30);
            IERC20Minimal(Currency.unwrap(currency1)).transfer(holders[i], 1e30);
        }

        address[3] memory placers = [address(this), user, attacker];
        for (uint256 i = 0; i < placers.length; i++) {
            vm.startPrank(placers[i]);
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
            vm.stopPrank();
        }

        vm.startPrank(swapper);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    // ------------------------------------- Helpers ------------------------------------- //

    /// @dev Order info without the `UserInfo` mapping.
    struct OrderInfoView {
        bool filled;
        Currency currency0;
        Currency currency1;
        uint256 principalCredited0;
        uint256 principalCredited1;
        uint256 accFee0PerLiqX128;
        uint256 accFee1PerLiqX128;
        uint128 liquidityTotal;
    }

    function getOrderInfoView(uint232 rawOrderId) internal view returns (OrderInfoView memory info) {
        (
            info.filled,
            info.currency0,
            info.currency1,
            info.principalCredited0,
            info.principalCredited1,
            info.accFee0PerLiqX128,
            info.accFee1PerLiqX128,
            info.liquidityTotal
        ) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(rawOrderId));
    }

    /// @dev Fees owed to `owner`, recomputed from the order accumulators and the owner's checkpoints.
    function feesOwedTo(uint232 rawOrderId, address owner) internal view returns (uint256, uint256) {
        LimitOrderHook.UserInfo memory info = hook.getUserInfo(OrderIdLibrary.OrderId.wrap(rawOrderId), owner);
        OrderInfoView memory order = getOrderInfoView(rawOrderId);
        return (
            FullMath.mulDiv(order.accFee0PerLiqX128 - info.feeCheckpoint0X128, info.liquidity, FixedPoint128.Q128),
            FullMath.mulDiv(order.accFee1PerLiqX128 - info.feeCheckpoint1X128, info.liquidity, FixedPoint128.Q128)
        );
    }

    /// @dev Principal owed to `owner`, its liquidity's pro-rata share of the credited principal.
    function principalOwedTo(uint232 rawOrderId, address owner) internal view returns (uint256, uint256) {
        LimitOrderHook.UserInfo memory info = hook.getUserInfo(OrderIdLibrary.OrderId.wrap(rawOrderId), owner);
        OrderInfoView memory order = getOrderInfoView(rawOrderId);
        if (info.liquidity == 0) return (0, 0);
        return (
            FullMath.mulDiv(order.principalCredited0, info.liquidity, order.liquidityTotal),
            FullMath.mulDiv(order.principalCredited1, info.liquidity, order.liquidityTotal)
        );
    }

    function rawOrderIdOf(PoolKey memory poolKey, int24 tickLower, bool zeroForOne) internal view returns (uint232) {
        return OrderIdLibrary.OrderId.unwrap(hook.getOrderId(poolKey, tickLower, zeroForOne));
    }

    /// @dev The expected position salt per direction, stated here rather than read from the hook.
    function positionSalt(bool zeroForOne) internal pure returns (bytes32) {
        return zeroForOne ? bytes32(uint256(1)) : bytes32(0);
    }

    function getLiquidityInPosition(PoolKey memory poolKey, int24 tickLower, bool zeroForOne)
        internal
        view
        returns (uint128)
    {
        return manager.getPositionLiquidity(
            poolKey.toId(),
            Position.calculatePositionKey(address(hook), tickLower, tickLower + tickSpacing, positionSalt(zeroForOne))
        );
    }

    function getCurrentTick(PoolKey memory poolKey) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolKey.toId());
    }

    /// @dev Swaps exact input until `tickLimit` is reached or the input is consumed.
    function swapToLimit(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, int24 tickLimit)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLimit)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Runs the swap in and out of the order's range on both pools, accruing fees without filling.
    function accrueFeesWithoutFilling() internal {
        vm.startPrank(swapper);
        swapToLimit(key, false, -1e18, tickSpacing / 2);
        swapToLimit(noHookKey, false, -1e18, tickSpacing / 2);
        swapToLimit(key, true, -1e18, -tickSpacing / 2);
        swapToLimit(noHookKey, true, -1e18, -tickSpacing / 2);
        vm.stopPrank();
    }

    // ------------------------------------- Place ------------------------------------- //

    function test_placeOrder_zeroLiquidity_reverts() public {
        vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
        hook.placeOrder(key, 0, true, 0);
    }

    function test_placeOrder_foreignPool_reverts() public {
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.placeOrder(noHookKey, tickSpacing, true, 1e18);
    }

    function test_cancelOrder_foreignPool_reverts() public {
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.cancelOrder(noHookKey, tickSpacing, false, address(this));
    }

    function test_placeOrder_simple() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        vm.expectEmit(true, true, false, true, address(hook));
        emit LimitOrderHook.Place(address(this), OrderIdLibrary.OrderId.wrap(1), key, tickLower, zeroForOne, liquidity);
        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        assertEq(rawOrderIdOf(key, tickLower, zeroForOne), 1, "first order should take order id 1");
        assertEq(getLiquidityInPosition(key, tickLower, zeroForOne), liquidity, "liquidity should be added to the pool");

        OrderInfoView memory order = getOrderInfoView(1);
        assertFalse(order.filled, "order should not be filled");
        assertEq(Currency.unwrap(order.currency0), Currency.unwrap(currency0), "currency0 should be recorded");
        assertEq(Currency.unwrap(order.currency1), Currency.unwrap(currency1), "currency1 should be recorded");
        assertEq(order.principalCredited0, 0, "principalCredited0 should be 0");
        assertEq(order.principalCredited1, 0, "principalCredited1 should be 0");
        assertEq(order.accFee0PerLiqX128, 0, "accFee0PerLiqX128 should be 0");
        assertEq(order.accFee1PerLiqX128, 0, "accFee1PerLiqX128 should be 0");
        assertEq(order.liquidityTotal, liquidity, "liquidity total should be accounted");

        LimitOrderHook.UserInfo memory userInfo = hook.getUserInfo(OrderIdLibrary.OrderId.wrap(1), address(this));
        assertEq(userInfo.liquidity, liquidity, "owner liquidity should be accounted");
        assertEq(userInfo.feeCheckpoint0X128, 0, "checkpoint0 should start at the accumulator");
        assertEq(userInfo.feeCheckpoint1X128, 0, "checkpoint1 should start at the accumulator");
    }

    function test_placeOrder_oneLiquidity_costsTokens() public {
        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));
        hook.placeOrder(key, tickSpacing, true, 1);
        uint256 balance0After = currency0.balanceOf(address(this));
        uint256 balance1After = currency1.balanceOf(address(this));
        assertTrue(balance0After < balance0Before || balance1After < balance1Before, "got one liquidity for free");
    }

    function test_placeOrder_rightBoundaryOfCurrentRange() public {
        int24 tickLower = tickSpacing;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, true, liquidity);

        assertEq(rawOrderIdOf(key, tickLower, true), 1, "first order should take order id 1");
        assertEq(getLiquidityInPosition(key, tickLower, true), liquidity, "liquidity should be added to the pool");
        assertEq(getOrderInfoView(1).liquidityTotal, liquidity, "liquidity total should be accounted");
    }

    function test_placeOrder_leftBoundaryOfCurrentRange_zeroForOne() public {
        int24 tickLower = 0;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, true, liquidity);

        assertEq(rawOrderIdOf(key, tickLower, true), 1, "first order should take order id 1");
        assertEq(getLiquidityInPosition(key, tickLower, true), liquidity, "liquidity should be added to the pool");
        assertEq(getOrderInfoView(1).liquidityTotal, liquidity, "liquidity total should be accounted");
    }

    /**
     * @dev At the exact boundary the pool counts the new liquidity as active, and the position is
     * nonetheless entirely in the currency the order sells. Placing and cancelling moves no currency1
     * in either direction, so a pro-rata split by liquidity is exact and the placement is single-sided
     * in substance, not only in the accounting.
     */
    function test_placeOrder_leftBoundaryOfCurrentRange_positionIsWhollyTheSoldCurrency() public {
        int24 tickLower = 0;
        uint128 liquidity = 1e18;

        (, int24 storedTick,,) = manager.getSlot0(key.toId());
        assertEq(storedTick, tickLower, "the pool should count a position at this tick as active");

        uint256 poolLiquidityBefore = manager.getLiquidity(key.toId());
        uint256 balance1Before = currency1.balanceOf(address(this));
        uint256 balance0Before = currency0.balanceOf(address(this));

        hook.placeOrder(key, tickLower, true, liquidity);

        assertEq(
            manager.getLiquidity(key.toId()),
            poolLiquidityBefore + liquidity,
            "the placement should join the pool's active liquidity"
        );
        assertEq(currency1.balanceOf(address(this)), balance1Before, "the placement should not spend currency1");
        assertLt(currency0.balanceOf(address(this)), balance0Before, "the placement should spend currency0");

        hook.cancelOrder(key, tickLower, true, address(this));

        assertEq(currency1.balanceOf(address(this)), balance1Before, "the cancel should not return currency1");
        assertLe(
            currency0.balanceOf(address(this)), balance0Before, "a place and cancel round trip should never pay out"
        );
        assertApproxEqAbs(
            currency0.balanceOf(address(this)), balance0Before, 1, "the cancel should return the currency0 placed"
        );
    }

    /// @dev Repeating the boundary round trip never pays the placer out, so the truncation dust cannot
    /// be farmed by cycling placements at the current tick.
    function test_placeOrder_leftBoundaryOfCurrentRange_roundTripNeverPaysOut() public {
        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));

        for (uint256 i; i < 20; ++i) {
            hook.placeOrder(key, 0, true, 1e18);
            hook.cancelOrder(key, 0, true, address(this));

            assertLe(currency0.balanceOf(address(this)), balance0Before, "a cycle paid out currency0");
            assertLe(currency1.balanceOf(address(this)), balance1Before, "a cycle paid out currency1");
        }
    }

    function test_placeOrder_crossedRange_reverts() public {
        vm.expectRevert(LimitOrderHook.CrossedRange.selector);
        hook.placeOrder(key, -tickSpacing, true, 1000000);
    }

    function test_placeOrder_inRange_reverts() public {
        // the pool has no liquidity, so a 1 wei swap moves the price to the limit
        vm.prank(swapper);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        vm.expectRevert(LimitOrderHook.InRange.selector);
        hook.placeOrder(key, 0, true, 1000000);
    }

    function test_placeOrder_leftBoundaryOfCurrentRange_oneForZero() public {
        int24 tickLower = -tickSpacing;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, false, liquidity);

        assertEq(rawOrderIdOf(key, tickLower, false), 1, "first order should take order id 1");
        assertEq(getLiquidityInPosition(key, tickLower, false), liquidity, "liquidity should be added to the pool");
        assertEq(getOrderInfoView(1).liquidityTotal, liquidity, "liquidity total should be accounted");
    }

    function test_placeOrder_crossedRange_oneForZero_reverts() public {
        vm.expectRevert(LimitOrderHook.CrossedRange.selector);
        hook.placeOrder(key, 0, false, 1000000);
    }

    function test_placeOrder_inRange_oneForZero_reverts() public {
        // the pool has no liquidity, so a 1 wei swap moves the price to the limit
        vm.prank(swapper);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        vm.expectRevert(LimitOrderHook.InRange.selector);
        hook.placeOrder(key, -tickSpacing, false, 1000000);
    }

    function test_placeOrder_multipleLPs() public {
        int24 tickLower = tickSpacing;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, true, liquidity);
        vm.prank(user);
        hook.placeOrder(key, tickLower, true, liquidity);

        assertEq(rawOrderIdOf(key, tickLower, true), 1, "both placements should share order id 1");
        assertEq(getLiquidityInPosition(key, tickLower, true), liquidity * 2, "liquidity should be added to the pool");
        assertEq(getOrderInfoView(1).liquidityTotal, liquidity * 2, "liquidity total should be accounted");
        assertEq(hook.getUserInfo(OrderIdLibrary.OrderId.wrap(1), address(this)).liquidity, liquidity);
        assertEq(hook.getUserInfo(OrderIdLibrary.OrderId.wrap(1), user).liquidity, liquidity);
    }

    function test_placeOrder_costMatchesPlainLiquidity() public {
        uint128 liquidity = 1e15;

        uint256 balance0Before = currency0.balanceOf(address(this));
        hook.placeOrder(key, tickSpacing, true, liquidity);
        uint256 placeCost = balance0Before - currency0.balanceOf(address(this));

        balance0Before = currency0.balanceOf(address(this));
        modifyPoolLiquidity(noHookKey, tickSpacing, 2 * tickSpacing, int256(uint256(liquidity)), SALT_THIS);
        uint256 addCost = balance0Before - currency0.balanceOf(address(this));

        assertEq(placeCost, addCost, "placing should cost the same as adding the liquidity directly");
    }

    function test_placeOrder_addingLiquidityKeepsFeesOwed() public {
        uint128 liquidity = 1e15;
        hook.placeOrder(key, 0, true, liquidity);

        accrueFeesWithoutFilling();

        // this placement collects the pending pool fees into the order, all owed to the sole owner
        hook.placeOrder(key, 0, true, liquidity);

        (uint256 owed0Before, uint256 owed1Before) = feesOwedTo(1, address(this));
        assertTrue(owed0Before > 0 || owed1Before > 0, "fees should be owed before adding liquidity");

        hook.placeOrder(key, 0, true, liquidity);

        (uint256 owed0After, uint256 owed1After) = feesOwedTo(1, address(this));
        assertApproxEqAbs(owed0After, owed0Before, 1, "adding liquidity should not change the fees owed");
        assertApproxEqAbs(owed1After, owed1Before, 1, "adding liquidity should not change the fees owed");
        assertEq(
            hook.getUserInfo(OrderIdLibrary.OrderId.wrap(1), address(this)).liquidity,
            3 * liquidity,
            "owner liquidity should be accumulated"
        );
    }

    function test_placeOrder_notEntitledToPriorFees() public {
        uint128 liquidity = 1e15;
        hook.placeOrder(key, 0, true, liquidity);

        accrueFeesWithoutFilling();

        vm.prank(user);
        hook.placeOrder(key, 0, true, liquidity);

        (uint256 userOwed0, uint256 userOwed1) = feesOwedTo(1, user);
        (uint256 thisOwed0, uint256 thisOwed1) = feesOwedTo(1, address(this));

        assertEq(userOwed0, 0, "joiner should not be owed prior fees");
        assertEq(userOwed1, 0, "joiner should not be owed prior fees");
        assertTrue(thisOwed0 > 0 || thisOwed1 > 0, "prior owner should keep the fees accrued before the join");
    }

    // ------------------------------------- Cancel ------------------------------------- //

    function test_cancelOrder() public {
        int24 tickLower = 0;
        uint128 liquidity = 1000000;

        uint256 balanceBefore = currency0.balanceOf(address(this));

        hook.placeOrder(key, tickLower, true, liquidity);

        vm.expectEmit(true, true, false, true, address(hook));
        emit LimitOrderHook.Cancel(address(this), OrderIdLibrary.OrderId.wrap(1), key, tickLower, true, liquidity);
        hook.cancelOrder(key, tickLower, true, address(this));

        OrderInfoView memory order = getOrderInfoView(1);
        assertFalse(order.filled, "order should not be filled");
        assertEq(order.liquidityTotal, 0, "liquidity total should be 0");
        assertEq(getLiquidityInPosition(key, tickLower, true), 0, "liquidity should be removed from the pool");
        assertEq(rawOrderIdOf(key, tickLower, true), 0, "emptied order should be deactivated");

        assertApproxEqAbs(
            currency0.balanceOf(address(this)), balanceBefore, 1, "lp should recover the cancelled liquidity"
        );
    }

    function test_cancelOrder_zeroLiquidity_reverts() public {
        vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
        hook.cancelOrder(key, 0, true, address(this));
    }

    function test_cancelOrder_afterFullCancel_newOrderId() public {
        hook.placeOrder(key, 0, true, 1000000);
        hook.cancelOrder(key, 0, true, address(this));

        hook.placeOrder(key, 0, true, 1000000);
        assertEq(rawOrderIdOf(key, 0, true), 2, "a placement after a full cancel should open a new order");
    }

    function test_cancelOrder_feesAccrued() public {
        uint128 liquidity = 1e15;

        // two owners on the hooked pool, mirrored by two positions on the hookless pool
        hook.placeOrder(key, 0, true, liquidity);
        vm.prank(user);
        hook.placeOrder(key, 0, true, liquidity);
        modifyPoolLiquidity(noHookKey, 0, tickSpacing, int256(uint256(liquidity)), SALT_THIS);
        vm.prank(user);
        modifyPoolLiquidity(noHookKey, 0, tickSpacing, int256(uint256(liquidity)), SALT_USER);

        accrueFeesWithoutFilling();

        // the swaps left fees pending in the pool position, to be collected by the cancellation
        (int128 pending0, int128 pending1) =
            calculateFees(manager, key.toId(), address(hook), 0, tickSpacing, positionSalt(true));
        assertTrue(pending0 > 0 || pending1 > 0, "fees should be pending in the order position");

        // cancelling pays out the same as removing the equivalent hookless position
        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));
        hook.cancelOrder(key, 0, true, address(this));
        uint256 received0 = currency0.balanceOf(address(this)) - balance0Before;
        uint256 received1 = currency1.balanceOf(address(this)) - balance1Before;

        BalanceDelta removeDelta =
            modifyPoolLiquidity(noHookKey, 0, tickSpacing, -int256(uint256(liquidity)), SALT_THIS);

        assertApproxEqAbs(
            received0, uint256(uint128(removeDelta.amount0())), DUST, "cancel should pay principal plus fee share"
        );
        assertApproxEqAbs(
            received1, uint256(uint128(removeDelta.amount1())), DUST, "cancel should pay principal plus fee share"
        );

        // the remaining owner keeps its liquidity and its own fee share
        OrderInfoView memory order = getOrderInfoView(1);
        assertEq(order.liquidityTotal, liquidity, "remaining owner liquidity should stay in the order");
        (uint256 userOwed0, uint256 userOwed1) = feesOwedTo(1, user);
        assertTrue(userOwed0 > 0 || userOwed1 > 0, "remaining owner should keep its fee share");
    }

    function test_cancelOrder_removingAllLiquidity() public {
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, true, liquidity);
        vm.prank(user);
        hook.placeOrder(key, 0, true, liquidity);

        accrueFeesWithoutFilling();

        (uint256 thisOwed0, uint256 thisOwed1) = feesOwedTo(1, address(this));
        (uint256 userOwed0, uint256 userOwed1) = feesOwedTo(1, user);
        assertApproxEqAbs(thisOwed0, userOwed0, 1, "equal owners should be owed equal fees");
        assertApproxEqAbs(thisOwed1, userOwed1, 1, "equal owners should be owed equal fees");

        hook.cancelOrder(key, 0, true, address(this));

        // the first cancel must not consume the second owner's entitlement
        (uint256 userOwed0After, uint256 userOwed1After) = feesOwedTo(1, user);
        assertGe(userOwed0After, userOwed0, "remaining owner entitlement should not decrease");
        assertGe(userOwed1After, userOwed1, "remaining owner entitlement should not decrease");

        uint256 balance0Before = currency0.balanceOf(user);
        uint256 balance1Before = currency1.balanceOf(user);
        vm.prank(user);
        hook.cancelOrder(key, 0, true, user);

        assertGe(currency0.balanceOf(user) - balance0Before, userOwed0After, "last canceller should get its fees");
        assertGe(currency1.balanceOf(user) - balance1Before, userOwed1After, "last canceller should get its fees");

        OrderInfoView memory order = getOrderInfoView(1);
        assertFalse(order.filled, "order should not be filled");
        assertEq(order.liquidityTotal, 0, "liquidity total should be 0");
        assertEq(getLiquidityInPosition(key, 0, true), 0, "liquidity should be removed from the pool");
        assertEq(rawOrderIdOf(key, 0, true), 0, "emptied order should be deactivated");
    }

    function test_cancelOrder_joinerCancelsImmediately_getsPrincipalOnly() public {
        uint128 liquidity = 1e15;
        hook.placeOrder(key, 0, true, liquidity);

        accrueFeesWithoutFilling();

        uint256 balance0Before = currency0.balanceOf(user);
        uint256 balance1Before = currency1.balanceOf(user);

        // join and cancel with no swap in between: no fees can be skimmed from the prior owner
        vm.startPrank(user);
        hook.placeOrder(key, 0, true, liquidity);
        hook.cancelOrder(key, 0, true, user);
        vm.stopPrank();

        assertApproxEqAbs(currency0.balanceOf(user), balance0Before, DUST, "joiner should only get its principal back");
        assertApproxEqAbs(currency1.balanceOf(user), balance1Before, DUST, "joiner should only get its principal back");

        (uint256 thisOwed0, uint256 thisOwed1) = feesOwedTo(1, address(this));
        assertTrue(thisOwed0 > 0 || thisOwed1 > 0, "prior owner should keep its fees");
    }

    // ------------------------------------- Fill ------------------------------------- //

    function test_fill_singleOwner() public {
        int24 tickLower = 0;
        uint128 liquidity = 1e15;

        hook.placeOrder(key, tickLower, true, liquidity);

        vm.expectEmit(true, false, false, true, address(hook));
        emit LimitOrderHook.Fill(OrderIdLibrary.OrderId.wrap(1), key, tickLower, true);
        vm.prank(swapper);
        swapToLimit(key, false, -1e18, 2 * tickSpacing);

        OrderInfoView memory order = getOrderInfoView(1);
        assertTrue(order.filled, "order should be filled");
        assertEq(order.principalCredited0, 0, "a zeroForOne fill should pay out only currency1");
        assertGt(order.principalCredited1, 0, "fill should credit the currency1 proceeds");
        assertEq(order.liquidityTotal, liquidity, "owners keep their liquidity accounted until withdrawal");
        assertEq(getLiquidityInPosition(key, tickLower, true), 0, "fill should remove the liquidity from the pool");
        assertEq(rawOrderIdOf(key, tickLower, true), 0, "filled order should be deactivated");
    }

    function test_fill_cancelAfterFill_reverts() public {
        hook.placeOrder(key, 0, true, 1e15);
        vm.prank(swapper);
        swapToLimit(key, false, -1e18, 2 * tickSpacing);

        vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
        hook.cancelOrder(key, 0, true, address(this));
    }

    function test_fill_placeAfterFill_newOrderId() public {
        hook.placeOrder(key, 0, true, 1e15);
        vm.prank(swapper);
        swapToLimit(key, false, -1e18, 2 * tickSpacing);

        // the price is above the range now, so the same tick is placeable in the other direction
        hook.placeOrder(key, 0, false, 1e15);
        assertEq(rawOrderIdOf(key, 0, false), 2, "a placement after a fill should open a new order");
        assertEq(getOrderInfoView(1).liquidityTotal, 1e15, "the filled order should be untouched");
    }

    function test_swapAcrossRange_partialCrossingsDoNotFill() public {
        int24 tickLower = 0;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, true, liquidity);

        vm.startPrank(swapper);
        // move well below the range
        swapToLimit(key, true, -1e17, tickLower - 10 * tickSpacing);
        assertEq(getCurrentTick(key), tickLower - 10 * tickSpacing, "tick after swap 1 is wrong");

        // move into the range without crossing it
        swapToLimit(key, false, -1e17, tickLower + tickSpacing / 2);
        assertEq(getCurrentTick(key), tickLower + tickSpacing / 2, "tick after swap 2 is wrong");

        // and back out below
        swapToLimit(key, true, -1e17, tickLower - tickSpacing / 2);
        vm.stopPrank();

        OrderInfoView memory order = getOrderInfoView(1);
        assertFalse(order.filled, "order should not be filled");
        assertEq(order.principalCredited0, 0, "no principal should be credited");
        assertEq(order.principalCredited1, 0, "no principal should be credited");
        assertEq(getLiquidityInPosition(key, tickLower, true), liquidity, "liquidity should remain in the pool");

        vm.expectRevert(LimitOrderHook.NotFilled.selector);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));
    }

    /**
     * @dev Places an order below spot, accrues fees on it with two-way flow, then lands the price exactly
     * on the order's tick. `Pool.swap` stores that tick minus one for a downward landing on an initialized
     * tick, which is what marks the order's range as no longer active.
     */
    function landOnOrdersTick(int24 orderTick, uint128 liquidity) internal {
        modifyPoolLiquidity(key, -6000, 6000, 1e21, SALT_THIS);

        vm.prank(user);
        hook.placeOrder(key, orderTick, false, liquidity);

        vm.startPrank(swapper);
        for (uint256 i; i < 4; ++i) {
            swapToLimit(key, true, -1e24, orderTick + 5);
            swapToLimit(key, false, -1e24, -5);
        }
        swapToLimit(key, true, -1e24, orderTick);
        vm.stopPrank();
    }

    /// @dev A downward landing exactly on an order's tick fills it, since the tick the pool stores marks
    /// the order's liquidity as wholly converted. Reading the price-derived tick left the order live.
    function test_fill_landingOnTheOrdersTick() public {
        int24 orderTick = -tickSpacing;
        landOnOrdersTick(orderTick, 1e18);

        (uint160 sqrtPriceX96, int24 storedTick,,) = manager.getSlot0(key.toId());
        assertEq(storedTick, orderTick - 1, "the pool should store the decremented tick");
        assertEq(TickMath.getTickAtSqrtPrice(sqrtPriceX96), orderTick, "the price should still read the order's tick");

        assertEq(getLiquidityInPosition(key, orderTick, false), 0, "the fill should empty the order's position");
        assertEq(rawOrderIdOf(key, orderTick, false), 0, "a filled order should retire its key");
    }

    /// @dev The two directions at one tick span the same range, so the position salt is what stops a later
    /// order from inheriting the position, and the fee balance, of the order filled out of the way.
    function test_fill_oppositeDirectionAtSameTickDoesNotShareAPosition() public {
        int24 orderTick = -tickSpacing;
        uint128 liquidity = 1e18;
        landOnOrdersTick(orderTick, liquidity);

        vm.prank(attacker);
        hook.placeOrder(key, orderTick, true, liquidity);

        assertEq(getLiquidityInPosition(key, orderTick, true), liquidity, "the new order's position is not its own");
        assertEq(getLiquidityInPosition(key, orderTick, false), 0, "the filled order's position should stay empty");

        OrderInfoView memory order = getOrderInfoView(rawOrderIdOf(key, orderTick, true));
        assertEq(order.accFee0PerLiqX128, 0, "the new order credited currency0 fees it did not earn");
        assertEq(order.accFee1PerLiqX128, 0, "the new order credited currency1 fees it did not earn");
    }

    // ------------------------------------- Withdraw ------------------------------------- //

    function test_withdraw_notFilled_reverts() public {
        hook.placeOrder(key, 0, true, 1e15);
        vm.expectRevert(LimitOrderHook.NotFilled.selector);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));
    }

    function test_withdraw_zeroLiquidity_reverts() public {
        hook.placeOrder(key, 0, true, 1e15);
        vm.prank(swapper);
        swapToLimit(key, false, -1e18, 2 * tickSpacing);

        vm.prank(user);
        vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
    }

    function test_withdraw_singleOwner() public {
        uint128 liquidity = 1e15;
        hook.placeOrder(key, 0, true, liquidity);
        vm.prank(swapper);
        swapToLimit(key, false, -1e18, 2 * tickSpacing);

        (uint256 principal0, uint256 principal1) = principalOwedTo(1, address(this));
        (uint256 owed0, uint256 owed1) = feesOwedTo(1, address(this));

        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));

        vm.expectEmit(true, true, false, true, address(hook));
        emit LimitOrderHook.Withdraw(address(this), OrderIdLibrary.OrderId.wrap(1), liquidity);
        (uint256 amount0, uint256 amount1) = hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));

        assertEq(amount0, principal0 + owed0, "withdraw should return the principal plus the fees owed");
        assertEq(amount1, principal1 + owed1, "withdraw should return the principal plus the fees owed");
        assertEq(currency0.balanceOf(address(this)) - balance0Before, amount0, "returned amount0 should be paid out");
        assertEq(currency1.balanceOf(address(this)) - balance1Before, amount1, "returned amount1 should be paid out");

        OrderInfoView memory order = getOrderInfoView(1);
        assertEq(order.liquidityTotal, 0, "liquidity total should be 0");
        assertEq(order.principalCredited0, 0, "principal should be fully paid out");
        assertEq(order.principalCredited1, 0, "principal should be fully paid out");
    }

    function test_withdraw_multipleLPs() public {
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, true, liquidity);
        vm.prank(user);
        hook.placeOrder(key, 0, true, liquidity);

        vm.prank(swapper);
        swapToLimit(key, false, -1e18, 2 * tickSpacing);

        uint256 totalPrincipal1 = getOrderInfoView(1).principalCredited1;
        assertGt(totalPrincipal1, 0, "fill should credit principal");

        vm.prank(user);
        (, uint256 userAmount1) = hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
        assertGe(userAmount1, totalPrincipal1 / 2, "withdrawal should pay at least the principal share");

        (, uint256 thisAmount1) = hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));

        // equal owners split the proceeds equally, and nothing is left behind
        assertApproxEqAbs(userAmount1, thisAmount1, DUST, "equal owners should receive equal payouts");

        OrderInfoView memory order = getOrderInfoView(1);
        assertEq(order.liquidityTotal, 0, "liquidity total should be 0");
        assertEq(order.principalCredited0, 0, "principal should be fully paid out");
        assertEq(order.principalCredited1, 0, "principal should be fully paid out");

        // a second withdrawal has nothing to claim
        vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));
    }

    function test_withdraw_noUnderflowAfterEarlierWithdrawals() public {
        int24 tickLower = 0;
        uint128 liquidity = 1e18;

        // first participant places, then substantial fees accrue on its liquidity alone
        hook.placeOrder(key, tickLower, true, liquidity);

        vm.startPrank(swapper);
        for (uint256 i = 0; i < 20; ++i) {
            swapToLimit(key, false, -5e20, tickSpacing / 2);
            swapToLimit(key, true, -5e20, -tickSpacing);
        }
        vm.stopPrank();

        // later participants join without diluting the accrued fees, which their placements collect
        vm.prank(user);
        hook.placeOrder(key, tickLower, true, liquidity);
        vm.prank(attacker);
        hook.placeOrder(key, tickLower, true, liquidity);

        (uint256 first0, uint256 first1) = feesOwedTo(1, address(this));
        assertTrue(first0 > 0 && first1 > 0, "fees should have accrued in both currencies");

        (uint256 joiner0, uint256 joiner1) = feesOwedTo(1, user);
        assertEq(joiner0, 0, "joiner should start with no fees owed");
        assertEq(joiner1, 0, "joiner should start with no fees owed");

        vm.prank(swapper);
        swapToLimit(key, false, -1e21, 2 * tickSpacing);
        assertTrue(getOrderInfoView(1).filled, "order should be filled");

        // withdrawing in sequence never underflows, even after the early fee accrual
        (uint256 amountA0, uint256 amountA1) = hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));
        vm.prank(user);
        (uint256 amountB0, uint256 amountB1) = hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
        vm.prank(attacker);
        (uint256 amountC0, uint256 amountC1) = hook.withdraw(OrderIdLibrary.OrderId.wrap(1), attacker);

        // the early fees belong to the first participant only
        assertGt(amountA0, amountB0, "first participant should keep the early fees");
        assertGt(amountA1, amountB1, "first participant should keep the early fees");
        assertApproxEqAbs(amountB0, amountC0, DUST, "equal joiners should receive equal payouts");
        assertApproxEqAbs(amountB1, amountC1, DUST, "equal joiners should receive equal payouts");

        OrderInfoView memory order = getOrderInfoView(1);
        assertEq(order.liquidityTotal, 0, "liquidity total should be 0");
        assertEq(order.principalCredited0, 0, "principal should be fully paid out");
        assertEq(order.principalCredited1, 0, "principal should be fully paid out");
    }

    function test_withdraw_feesAccruedJIT() public {
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, true, liquidity);

        accrueFeesWithoutFilling();

        // attacker joins just before the fill; its placement collects the pending fees over the
        // first owner's liquidity alone
        vm.prank(attacker);
        hook.placeOrder(key, 0, true, liquidity);

        (uint256 preJoin0, uint256 preJoin1) = feesOwedTo(1, address(this));
        assertTrue(preJoin0 > 0 || preJoin1 > 0, "fees should be owed to the first owner");

        vm.prank(swapper);
        swapToLimit(key, false, -1e18, 2 * tickSpacing);

        // the attacker is owed only its share of the fees accrued after it joined
        (uint256 attacker0, uint256 attacker1) = feesOwedTo(1, attacker);
        (uint256 owner0, uint256 owner1) = feesOwedTo(1, address(this));
        assertEq(attacker0, 0, "no currency0 fees accrued after the join");
        assertApproxEqAbs(owner0, preJoin0, 1, "pre-join currency0 fees should stay with the first owner");
        assertApproxEqAbs(owner1 - attacker1, preJoin1, DUST, "the owners should differ exactly by the pre-join fees");

        // payouts follow the entitlements
        vm.prank(attacker);
        (uint256 attackerAmount0, uint256 attackerAmount1) = hook.withdraw(OrderIdLibrary.OrderId.wrap(1), attacker);
        (uint256 ownerAmount0, uint256 ownerAmount1) = hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));

        assertApproxEqAbs(ownerAmount0 - attackerAmount0, preJoin0, DUST, "attacker should not skim currency0 fees");
        assertApproxEqAbs(ownerAmount1 - attackerAmount1, preJoin1, DUST, "attacker should not skim currency1 fees");
    }

    // ------------------------------------- Getters ------------------------------------- //

    function test_getTickLowerLast() public {
        assertEq(hook.getTickLowerLast(key.toId()), 0, "initialization should record the current tick lower");

        vm.prank(swapper);
        swapToLimit(key, true, -1 ether, -10 * tickSpacing);

        assertEq(hook.getTickLowerLast(key.toId()), -10 * tickSpacing, "swaps should update the tick lower last");
    }
}
