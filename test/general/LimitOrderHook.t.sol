// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// Internal imports
import {LimitOrderHook, OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {LimitOrderHookMock} from "../../src/mocks/general/LimitOrderHookMock.sol";
import {HookTest} from "../utils/HookTest.sol";

contract LimitOrderHookTest is HookTest {
    using StateLibrary for IPoolManager;

    LimitOrderHookMock hook;

    PoolKey noHookKey;

    address user = makeAddr("user");
    address swapper = makeAddr("swapper");
    address attacker = makeAddr("attacker");
    int24 tickSpacing;

    bool filled;
    uint256 currency0Total; // currency0 total in the order
    uint256 currency1Total; // currency1 total in the order
    uint128 liquidityTotal; // liquidity total in the order

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

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(user, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(user, 1e30);
        IERC20Minimal(Currency.unwrap(currency0)).transfer(swapper, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(swapper, 1e30);
        IERC20Minimal(Currency.unwrap(currency0)).transfer(attacker, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(attacker, 1e30);

        vm.startPrank(user);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityNoChecks), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityNoChecks), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(swapper);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(attacker);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityNoChecks), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityNoChecks), type(uint256).max);
        vm.stopPrank();

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function calculateExpectedFees(
        IPoolManager manager,
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (int128, int128) {
        bytes32 positionKey = Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            StateLibrary.getPositionInfo(manager, poolId, positionKey);

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            StateLibrary.getFeeGrowthInside(manager, poolId, tickLower, tickUpper);

        uint256 feesExpected0 =
            FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
        uint256 feesExpected1 =
            FullMath.mulDiv(feeGrowthInside1X128 - feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);

        return (int128(int256(feesExpected0)), int128(int256(feesExpected1)));
    }

    function modifyPoolLiquidityNoChecks(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity,
        bytes32 salt
    ) internal returns (BalanceDelta) {
        ModifyLiquidityParams memory modifyLiquidityParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: salt
        });
        return modifyLiquidityNoChecks.modifyLiquidity(poolKey, modifyLiquidityParams, "");
    }

    function swapOnPool(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // Helpers
    function getCurrentTick(PoolId poolId) public view returns (int24 tick) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function test_getTickLowerLast() public view {
        assertEq(hook.getTickLowerLast(key.toId()), 0);
    }

    function test_zeroLiquidityRevert() public {
        vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
        hook.placeOrder(key, 0, true, 0);
    }

    function test_zeroForOneRightBoundaryOfCurrentRange() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);
    }

    function test_zeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);
    }

    function test_zeroForOneCrossedRangeRevert() public {
        vm.expectRevert(LimitOrderHook.CrossedRange.selector);
        hook.placeOrder(key, -60, true, 1000000);
    }

    function test_zeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.expectRevert(LimitOrderHook.InRange.selector);
        hook.placeOrder(key, 0, true, 1000000);
    }

    function test_notZeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = -60;
        bool zeroForOne = false;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);
    }

    function test_notZeroForOneCrossedRangeRevert() public {
        vm.expectRevert(LimitOrderHook.CrossedRange.selector);
        hook.placeOrder(key, 0, false, 1000000);
    }

    function test_notZeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.expectRevert(LimitOrderHook.InRange.selector);
        hook.placeOrder(key, -60, false, 1000000);
    }

    function test_multipleLPs() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        vm.startPrank(user);
        hook.placeOrder(key, tickLower, zeroForOne, liquidity);
        vm.stopPrank();

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity * 2);

        Currency orderCurrency0;
        Currency orderCurrency1;
        (filled, orderCurrency0, orderCurrency1, currency0Total, currency1Total, liquidityTotal) =
            hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));
        assertFalse(filled);
        assertTrue(currency0 == orderCurrency0);
        assertTrue(currency1 == orderCurrency1);
        assertEq(currency0Total, 0);
        assertEq(currency1Total, 0);
        assertEq(liquidityTotal, liquidity * 2);
        assertEq(hook.getOrderLiquidity(OrderIdLibrary.OrderId.wrap(1), address(this)), liquidity);
        assertEq(hook.getOrderLiquidity(OrderIdLibrary.OrderId.wrap(1), user), liquidity);
    }

    function test_cancelOrder() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        uint256 balanceBefore = currency0.balanceOf(address(this));

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        hook.cancelOrder(key, tickLower, zeroForOne, address(this));

        uint256 balanceAfterCancel = currency0.balanceOf(address(this));

        assertApproxEqAbs(balanceBefore, balanceAfterCancel, 1);
    }

    function test_cancelOrder_feesAccrued() public {
        bool zeroForOne = true;
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, zeroForOne, liquidity);

        //place order is the same as add liquidity to the pool in the range (0, tickSpacing)
        vm.startPrank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        // add liquidity equivalent to two orders
        modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, int256(uint256(2 * liquidity)), 0);
        vm.stopPrank();

        // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        vm.stopPrank();

        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertFalse(filled, "order should not be filled");
        assertEq(currency0Total, 0, "currency0Total should be 0");
        assertEq(currency1Total, 0, "currency1Total should be 0");
        assertEq(liquidityTotal, 2 * liquidity, "liquidityTotal should be 2*liquidity");

        int256 balance0Before = int256(currency0.balanceOf(address(this)));
        int256 balance1Before = int256(currency1.balanceOf(address(this)));
        hook.cancelOrder(key, 0, zeroForOne, address(this));
        int256 balance0AfterCancel = int256(currency0.balanceOf(address(this)));
        int256 balance1AfterCancel = int256(currency1.balanceOf(address(this)));

        // cancel the order is the same as remove liquidity from the pool in the range (0, tickSpacing)
        vm.startPrank(user);
        (int128 feesExpected0, int128 feesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityNoChecks), 0, key.tickSpacing, 0);
        BalanceDelta delta = modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);
        vm.stopPrank();

        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertEq(currency0Total, uint256(uint128(feesExpected0)));
        assertEq(currency1Total, uint256(uint128(feesExpected1)));

        assertTrue(feesExpected0 > 0 || feesExpected1 > 0);

        // canceling the order is the same as removing liquidity, minus the fees accrued to the order (which are in currency total)
        assertEq(balance0AfterCancel - balance0Before, int256(delta.amount0()) - int256(currency0Total));
        assertEq(balance1AfterCancel - balance1Before, int256(delta.amount1()) - int256(currency1Total));
    }

    function test_cancelOrder_removingAllLiquidity() public {
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        // first user places an order
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        // second user places an order
        vm.startPrank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);
        // add liquidity equivalent to two orders
        modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, int256(uint256(2 * liquidity)), 0);
        vm.stopPrank();

        // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        vm.stopPrank();

        // first user cancels the order
        hook.cancelOrder(key, 0, zeroForOne, address(this));

        // now second user cancels the order
        vm.startPrank(user);
        int256 balanceUser0Before = int256(currency0.balanceOf(user));
        int256 balanceUser1Before = int256(currency1.balanceOf(user));
        hook.cancelOrder(key, 0, zeroForOne, user);
        int256 balanceUser0After = int256(currency0.balanceOf(user));
        int256 balanceUser1After = int256(currency1.balanceOf(user));
        vm.stopPrank();

        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));
        assertEq(filled, false, "order should not be filled");
        assertEq(liquidityTotal, 0, "liquidityTotal should be liquidity");
        assertEq(currency0Total, 0, "currency0Total should be 0");
        assertEq(currency1Total, 0, "currency1Total should be 0");

        // cancel the order is the same as remove liquidity from the pool in the range (0, tickSpacing)
        vm.startPrank(user);
        (int128 feesExpected0, int128 feesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityNoChecks), 0, key.tickSpacing, 0);
        BalanceDelta delta = modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);
        vm.stopPrank();

        assertTrue(feesExpected0 > 0 || feesExpected1 > 0);

        // all fees accrued go to the last user to cancel the order, so their balance change
        // equals the full mirror delta (principal + position fees).
        assertEq(balanceUser0After - balanceUser0Before, int256(delta.amount0()));
        assertEq(balanceUser1After - balanceUser1Before, int256(delta.amount1()));
    }

    function test_placeOrder_feesAccrued() public {
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, 0, zeroForOne, liquidity);

        //place order is the same as add liquidity to the pool in the range (0, tickSpacing)
        vm.startPrank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        // add liquidity equivalent to two orders
        modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, int256(uint256(2 * liquidity)), 0);
        vm.stopPrank();

        // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));

        // swap outside of the range (0, tickSpacing) without filling the order to be able to place orders again
        swapOnPool(noHookKey, true, -1e15, TickMath.getSqrtPriceAtTick(-key.tickSpacing));
        swapOnPool(key, true, -1e15, TickMath.getSqrtPriceAtTick(-key.tickSpacing));

        vm.stopPrank();

        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertFalse(filled, "order should not be filled");
        assertEq(currency0Total, 0, "currency0Total should be 0");
        assertEq(currency1Total, 0, "currency1Total should be 0");
        assertEq(liquidityTotal, 2 * liquidity, "liquidityTotal should be 2*liquidity");

        int256 balance0Before = int256(currency0.balanceOf(address(this)));
        int256 balance1Before = int256(currency1.balanceOf(address(this)));
        hook.placeOrder(key, 0, zeroForOne, liquidity);
        int256 balance0AfterPlace = int256(currency0.balanceOf(address(this)));
        int256 balance1AfterPlace = int256(currency1.balanceOf(address(this)));

        // place the order is the same as add liquidity to the pool in the range (0, tickSpacing)

        vm.startPrank(user);
        (int128 feesExpected0, int128 feesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityNoChecks), 0, key.tickSpacing, 0);
        BalanceDelta delta = modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, int256(uint256(liquidity)), 0);
        vm.stopPrank();
        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertFalse(filled, "order should not be filled");
        assertEq(liquidityTotal, 3 * liquidity, "liquidityTotal should be 3*liquidity");

        assertEq(currency0Total, uint256(uint128(feesExpected0)), "currency0Total should be feesExpected0");
        assertEq(currency1Total, uint256(uint128(feesExpected1)), "currency1Total should be feesExpected1");

        assertTrue(feesExpected0 > 0 || feesExpected1 > 0, "fees should be accrued");

        // placing the order is the same as adding liquidity, plus the fees accrued to the order (which are in currency total)
        assertEq(
            balance0AfterPlace - balance0Before,
            int256(delta.amount0()) - int256(currency0Total),
            "fees were not held in currency0Total"
        );
        assertEq(
            balance1AfterPlace - balance1Before,
            int256(delta.amount1()) - int256(currency1Total),
            "fees were not held in currency1Total"
        );
    }

    function test_withdraw_multipleLPs() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        currency0.transfer(user, 1e18);
        currency1.transfer(user, 1e18);

        vm.startPrank(user);
        hook.placeOrder(key, tickLower, zeroForOne, liquidity);
        vm.stopPrank();

        assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity * 2);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower + key.tickSpacing)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertTrue(filled, "order should be filled");
        assertEq(currency0Total, 0, "wrong amount of currency0");
        assertEq(currency1Total, 2 * (2996 + 17), "wrong amount of currency1");

        vm.startPrank(user);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
        vm.stopPrank();

        (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertTrue(filled, "order should be filled");
        assertEq(currency0Total, 0, "wrong amount of currency0");
        assertEq(currency1Total, 2996 + 17, "wrong amount of currency1");

        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));

        (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertTrue(filled, "order should be filled");
        assertEq(currency0Total, 0, "wrong amount of currency0");
        assertEq(currency1Total, 0, "wrong amount of currency1");
    }

    function test_withdraw_feesAccruedFromCancel() public {
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        // first user places an order
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        // second user places an order
        vm.startPrank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);
        // add liquidity equivalent to two orders
        modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, int256(uint256(2 * liquidity)), 0);
        vm.stopPrank();

        // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        vm.stopPrank();

        // first user cancels the order
        hook.cancelOrder(key, 0, zeroForOne, address(this));

        vm.startPrank(user);
        (int128 initialFeesExpected0, int128 initialFeesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityNoChecks), 0, key.tickSpacing, 0);
        BalanceDelta delta = modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);
        vm.stopPrank();

        assertTrue(initialFeesExpected0 > 0 || initialFeesExpected1 > 0, "fees should be accrued");

        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertFalse(filled, "order should not be filled");
        assertEq(liquidityTotal, liquidity, "liquidityTotal should be liquidity");
        assertEq(currency0Total, uint256(uint128(initialFeesExpected0)), "currency0Total should be feesExpected0");
        assertEq(currency1Total, uint256(uint128(initialFeesExpected1)), "currency1Total should be feesExpected1");

        // this swap should fill the order, cross the range (0, tickSpacing)
        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(2 * key.tickSpacing));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(2 * key.tickSpacing));
        vm.stopPrank();

        // second user withdraws the order
        vm.startPrank(user);
        int256 balanceUser0Before = int256(currency0.balanceOf(user));
        int256 balanceUser1Before = int256(currency1.balanceOf(user));
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
        int256 balanceUser0After = int256(currency0.balanceOf(user));
        int256 balanceUser1After = int256(currency1.balanceOf(user));
        vm.stopPrank();

        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertTrue(filled, "order should be filled");
        assertEq(currency0Total, 0, "currency0Total should be 0");
        assertEq(currency1Total, 0, "currency1Total should be 0");
        assertEq(liquidityTotal, 0, "liquidityTotal should be 0");

        // cancel the order is the same as remove liquidity from the pool in the range (0, tickSpacing)
        vm.startPrank(user);
        delta = modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);
        vm.stopPrank();

        // the fees are added to the balance of the user who withdraws the order
        assertEq(balanceUser0After - balanceUser0Before, int256(delta.amount0()) + int256(initialFeesExpected0));
        assertEq(balanceUser1After - balanceUser1Before, int256(delta.amount1()) + int256(initialFeesExpected1));
    }

    function test_withdraw_feesAccruedJIT() public {
        // some user places an order
        hook.placeOrder(key, 0, true, 1e15);

        // user places the same order as the first user
        vm.startPrank(user);
        hook.placeOrder(key, 0, true, 1e15);
        // add liquidity equivalent to 2 orders
        modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, int256(uint256(2 * 1e15)), 0);
        vm.stopPrank();

        vm.startPrank(swapper);
        // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(tickSpacing / 2));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(tickSpacing / 2));

        // swap outside of the range (0, tickSpacing) without filling the order to be able to place orders again
        swapOnPool(key, true, -1e15, TickMath.getSqrtPriceAtTick(-tickSpacing));
        swapOnPool(noHookKey, true, -1e15, TickMath.getSqrtPriceAtTick(-tickSpacing));
        vm.stopPrank();

        // some user cancels the order, which accrues fees to the order
        hook.cancelOrder(key, 0, true, address(this));

        // attacker places the same order as the first user
        vm.startPrank(attacker);
        hook.placeOrder(key, 0, true, 1e15);
        vm.stopPrank();

        // add liquidity to be equivalent as placing the order
        vm.startPrank(user);
        (int128 initialFeesExpected0, int128 initialFeesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityNoChecks), 0, tickSpacing, 0);
        modifyPoolLiquidityNoChecks(noHookKey, 0, tickSpacing, int256(uint256(1e15)), 0);
        vm.stopPrank();

        vm.startPrank(user);
        BalanceDelta delta = modifyPoolLiquidityNoChecks(noHookKey, 0, tickSpacing, -int256(uint256(1e15)), 0);
        vm.stopPrank();

        assertTrue(initialFeesExpected0 > 0 || initialFeesExpected1 > 0, "fees should be accrued");

        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertFalse(filled, "order should not be filled");
        assertEq(liquidityTotal, 1e15 * 2, "liquidityTotal should be 2 * liquidity");
        assertApproxEqAbs(
            currency0Total, uint256(uint128(initialFeesExpected0)), 1, "currency0Total should be the fees accrued"
        );
        assertApproxEqAbs(
            currency1Total, uint256(uint128(initialFeesExpected1)), 1, "currency1Total should be the fees accrued"
        );

        // this swap should fill the order, cross the range (0, tickSpacing)
        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(2 * tickSpacing));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(2 * tickSpacing));
        vm.stopPrank();

        vm.startPrank(user);
        delta = modifyPoolLiquidityNoChecks(noHookKey, 0, tickSpacing, -int256(uint256(2 * 1e15)), 0);
        vm.stopPrank();

        (,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        // currency on the hook should be delta
        assertEq(
            currency0Total,
            uint256(uint128(delta.amount0())) + uint256(uint128(initialFeesExpected0)),
            "currency0Total should be the delta.amount0() + initialFeesExpected0"
        );
        assertEq(
            currency1Total,
            uint256(uint128(delta.amount1())) + uint256(uint128(initialFeesExpected1)),
            "currency1Total should be the delta.amount1() + initialFeesExpected1"
        );

        // attacker withdraws the order
        vm.startPrank(attacker);
        int256 balanceAttacker0Before = int256(currency0.balanceOf(attacker));
        int256 balanceAttacker1Before = int256(currency1.balanceOf(attacker));
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), attacker);
        int256 balanceAttacker0After = int256(currency0.balanceOf(attacker));
        int256 balanceAttacker1After = int256(currency1.balanceOf(attacker));
        vm.stopPrank();

        uint256 currency0Total2;
        uint256 currency1Total2;

        (filled,,, currency0Total2, currency1Total2, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertTrue(filled, "order should be filled");
        assertEq(liquidityTotal, 1e15, "liquidityTotal should be liquidity");
        assertApproxEqAbs(currency0Total2, currency0Total, 1, "attacker should not withdraw fees accrued");
        assertApproxEqAbs(
            currency1Total2,
            currency1Total / 2 + uint256(uint128(initialFeesExpected1)) / 2,
            1,
            "attacker should not withdraw fees accrued"
        );

        // cancel the order is the same as remove liquidity from the pool in the range (0, tickSpacing)
        vm.startPrank(user);

        int256 balanceUser0BeforeWithdraw = int256(currency0.balanceOf(user));
        int256 balanceUser1BeforeWithdraw = int256(currency1.balanceOf(user));
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
        int256 balanceUser0AfterWithdraw = int256(currency0.balanceOf(user));
        int256 balanceUser1AfterWithdraw = int256(currency1.balanceOf(user));
        vm.stopPrank();

        (,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertEq(liquidityTotal, 0, "liquidityTotal should be 0");
        assertEq(currency0Total, 0, "currency0Total should be 0");
        assertEq(currency1Total, 0, "currency1Total should be 0");

        assertApproxEqAbs(
            balanceAttacker0After - balanceAttacker0Before,
            balanceUser0AfterWithdraw - balanceUser0BeforeWithdraw - int256(uint256(uint128(initialFeesExpected0))),
            1,
            "fees should go to the user who withdraws the order"
        );
        assertApproxEqAbs(
            balanceAttacker1After - balanceAttacker1Before,
            balanceUser1AfterWithdraw - balanceUser1BeforeWithdraw - int256(uint256(uint128(initialFeesExpected1))),
            1,
            "fees should go to the user who withdraws the order"
        );
    }

    function test_swapAcrossRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;

        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        int24 currentTick = getCurrentTick(key.toId());

        assertEq(currentTick, tickLower, "Initial tick is wrong");

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e17,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower - 10 * key.tickSpacing)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        currentTick = getCurrentTick(key.toId());
        assertEq(currentTick, tickLower - 10 * key.tickSpacing, "Tick after swap 1 is wrong");

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1e17,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower + key.tickSpacing / 2)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        currentTick = getCurrentTick(key.toId());
        assertEq(currentTick, tickLower + key.tickSpacing / 2, "Tick after swap 2 is wrong");

        (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e17,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower - key.tickSpacing / 2)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        assertFalse(filled, "order should be filled");
        assertEq(currency0Total, 0, "wrong amount of currency0");
        assertEq(currency1Total, 0, "wrong amount of currency1"); // 3013, 2 wei of dust

        bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
        assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);

        vm.expectRevert(LimitOrderHook.NotFilled.selector);
        hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));
    }

    /// @dev Final cancellation releases the hook's ERC-6909 fee claims accrued by an earlier intermediate cancel.
    function test_cancelOrder_finalCancel_releasesAccruedFees() public {
        bool zeroForOne = true;
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, zeroForOne, liquidity);
        vm.prank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);

        // accrue fees on the 2L position without crossing the order's tick
        vm.prank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));

        // intermediate cancellation: accrued fees are minted to the hook as ERC-6909 claims
        hook.cancelOrder(key, 0, zeroForOne, address(this));

        uint256 hookBal0 = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookBal1 = manager.balanceOf(address(hook), currency1.toId());
        assertTrue(hookBal0 > 0 || hookBal1 > 0, "fees should accrue to hook on intermediate cancel");

        (,,, uint256 c0Total, uint256 c1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));
        assertEq(c0Total, hookBal0, "currency0Total should match hook claims");
        assertEq(c1Total, hookBal1, "currency1Total should match hook claims");

        // final cancellation: the hook's claims should be released as part of cancelling the order
        vm.prank(user);
        hook.cancelOrder(key, 0, zeroForOne, user);

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook retained currency0 claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook retained currency1 claims");

        assertTrue(
            OrderIdLibrary.equals(hook.getOrderId(key, 0, zeroForOne), OrderIdLibrary.OrderId.wrap(0)),
            "order id should be reset"
        );
        (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));
        assertFalse(filled);
        assertEq(liquidityTotal, 0);
        assertEq(currency0Total, 0);
        assertEq(currency1Total, 0);
    }

    /// @dev Final canceller receives principal + previously accrued fees, matched against the no-hook mirror.
    function test_cancelOrder_finalCancel_receivesPriorFees() public {
        bool zeroForOne = true;
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, zeroForOne, liquidity);

        vm.startPrank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);
        modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, int256(uint256(2 * liquidity)), 0);
        vm.stopPrank();

        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        vm.stopPrank();

        // intermediate cancel on `key` mints accrued fees to the hook
        hook.cancelOrder(key, 0, zeroForOne, address(this));

        // capture the position fees on the mirror pool before removing one user's worth.
        // delta = principal_for_L + position_fees, so it equals what the final canceller should receive.
        (int128 feesExpected0, int128 feesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityNoChecks), 0, key.tickSpacing, 0);
        assertTrue(feesExpected0 > 0 || feesExpected1 > 0, "fees should have accrued");

        vm.prank(user);
        BalanceDelta delta = modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);

        int256 balance0Before = int256(currency0.balanceOf(user));
        int256 balance1Before = int256(currency1.balanceOf(user));
        vm.prank(user);
        hook.cancelOrder(key, 0, zeroForOne, user);
        int256 balance0After = int256(currency0.balanceOf(user));
        int256 balance1After = int256(currency1.balanceOf(user));

        assertEq(balance0After - balance0Before, int256(delta.amount0()), "currency0 mismatch on final cancel");
        assertEq(balance1After - balance1Before, int256(delta.amount1()), "currency1 mismatch on final cancel");
    }

    /// @dev Fee claims accumulated across multiple intermediate cancels are all released to the final canceller.
    function test_cancelOrder_finalCancel_threeParticipants() public {
        bool zeroForOne = true;
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, zeroForOne, liquidity);
        vm.prank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);
        vm.prank(attacker);
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        // first batch of fees on the 3L position
        vm.prank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));

        hook.cancelOrder(key, 0, zeroForOne, address(this));

        uint256 hookBal0AfterFirst = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookBal1AfterFirst = manager.balanceOf(address(hook), currency1.toId());
        assertTrue(hookBal0AfterFirst > 0 || hookBal1AfterFirst > 0, "fees should accrue on first cancel");

        // second batch of fees on the 2L position; bring the price back into range first
        vm.startPrank(swapper);
        swapOnPool(key, true, -1e20, TickMath.getSqrtPriceAtTick(0));
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        vm.stopPrank();

        vm.prank(user);
        hook.cancelOrder(key, 0, zeroForOne, user);

        uint256 hookBal0BeforeFinal = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookBal1BeforeFinal = manager.balanceOf(address(hook), currency1.toId());

        assertTrue(
            hookBal0BeforeFinal > hookBal0AfterFirst || hookBal1BeforeFinal > hookBal1AfterFirst,
            "second intermediate cancel should add fees"
        );

        (,,, uint256 c0TotalBeforeFinal, uint256 c1TotalBeforeFinal,) =
            hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));
        assertEq(c0TotalBeforeFinal, hookBal0BeforeFinal);
        assertEq(c1TotalBeforeFinal, hookBal1BeforeFinal);

        uint256 cBal0Before = currency0.balanceOf(attacker);
        uint256 cBal1Before = currency1.balanceOf(attacker);
        vm.prank(attacker);
        hook.cancelOrder(key, 0, zeroForOne, attacker);

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook retained currency0 claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook retained currency1 claims");

        // final canceller's balance increase covers at least the previously accumulated claims
        assertGe(
            currency0.balanceOf(attacker) - cBal0Before,
            hookBal0BeforeFinal,
            "final canceller should receive prior currency0 fees"
        );
        assertGe(
            currency1.balanceOf(attacker) - cBal1Before,
            hookBal1BeforeFinal,
            "final canceller should receive prior currency1 fees"
        );
    }

    /// @dev With a single participant the cancel is also the final cancel; no claims are stranded.
    function test_cancelOrder_finalCancel_singleParticipant() public {
        bool zeroForOne = true;
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, zeroForOne, liquidity);

        vm.prank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));

        hook.cancelOrder(key, 0, zeroForOne, address(this));

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);

        assertTrue(
            OrderIdLibrary.equals(hook.getOrderId(key, 0, zeroForOne), OrderIdLibrary.OrderId.wrap(0)),
            "order id should be reset"
        );
    }

    /// @dev Fee claims minted to the hook by the place callback (not just by intermediate cancels)
    /// are also released to the canceller on final cancellation.
    function test_cancelOrder_finalCancel_releasesPlaceCallbackFees() public {
        bool zeroForOne = true;
        uint128 liquidity = 1e15;

        hook.placeOrder(key, 0, zeroForOne, liquidity);

        // accrue fees in-range, then push the price below the position so we can re-place without
        // hitting the in-range check
        vm.startPrank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));
        swapOnPool(key, true, -1e20, TickMath.getSqrtPriceAtTick(-key.tickSpacing));
        vm.stopPrank();

        // re-placement triggers the place callback, which mints the position's accrued fees to the hook
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        uint256 hookBal0 = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookBal1 = manager.balanceOf(address(hook), currency1.toId());
        assertTrue(hookBal0 > 0 || hookBal1 > 0, "place callback should mint fee claims to the hook");

        (,,, uint256 c0Total, uint256 c1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));
        assertEq(c0Total, hookBal0, "currency0Total should match hook claims");
        assertEq(c1Total, hookBal1, "currency1Total should match hook claims");

        // single canceller -> removingAllLiquidity == true. The pre-existing claims must be released.
        hook.cancelOrder(key, 0, zeroForOne, address(this));

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook retained currency0 claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook retained currency1 claims");
    }

    /// @dev On final cancellation, the principal and the released prior fees go to `to`, not to msg.sender.
    function test_cancelOrder_finalCancel_separateRecipient() public {
        bool zeroForOne = true;
        uint128 liquidity = 1e15;

        address recipient = makeAddr("recipient");

        hook.placeOrder(key, 0, zeroForOne, liquidity);
        vm.prank(user);
        hook.placeOrder(key, 0, zeroForOne, liquidity);

        vm.prank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));

        hook.cancelOrder(key, 0, zeroForOne, address(this));

        uint256 hookBal0BeforeFinal = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookBal1BeforeFinal = manager.balanceOf(address(hook), currency1.toId());
        assertTrue(hookBal0BeforeFinal > 0 || hookBal1BeforeFinal > 0, "intermediate cancel should mint fee claims");

        uint256 senderBal0Before = currency0.balanceOf(user);
        uint256 senderBal1Before = currency1.balanceOf(user);

        vm.prank(user);
        hook.cancelOrder(key, 0, zeroForOne, recipient);

        // msg.sender's balance is unchanged
        assertEq(currency0.balanceOf(user), senderBal0Before, "msg.sender should not receive currency0");
        assertEq(currency1.balanceOf(user), senderBal1Before, "msg.sender should not receive currency1");

        // recipient receives at least the previously stranded claims plus their principal
        assertGe(currency0.balanceOf(recipient), hookBal0BeforeFinal, "recipient should receive prior currency0 fees");
        assertGe(currency1.balanceOf(recipient), hookBal1BeforeFinal, "recipient should receive prior currency1 fees");

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    /// @dev Final cancellation of one order must not touch another order's accounting or hook claims.
    function test_cancelOrder_finalCancel_doesNotAffectOtherOrders() public {
        uint128 liquidity = 1e15;
        int24 tickA = 0;
        int24 tickB = -key.tickSpacing;

        // order A: zeroForOne=true at tick 0, position [0, tickSpacing) - filled when price crosses up through 0
        // order B: zeroForOne=false at tick -tickSpacing, position [-tickSpacing, 0) - filled when price crosses down through 0
        // both can be placed at the boundary currentTick=0 without hitting in-range / wrong-side reverts.
        hook.placeOrder(key, tickA, true, liquidity);
        vm.prank(user);
        hook.placeOrder(key, tickA, true, liquidity);

        hook.placeOrder(key, tickB, false, liquidity);
        vm.prank(user);
        hook.placeOrder(key, tickB, false, liquidity);

        OrderIdLibrary.OrderId orderAId = hook.getOrderId(key, tickA, true);
        OrderIdLibrary.OrderId orderBId = hook.getOrderId(key, tickB, false);

        // accrue fees on A by swapping up into [0, tickSpacing); the bucketed tick stays at 0 so no fill triggers
        vm.prank(swapper);
        swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(key.tickSpacing / 2));

        // accrue fees on B by swapping back through 0 into [-tickSpacing, 0); the cross-tick check at tick 0
        // looks for a zeroForOne=false order at tickLower=0, which doesn't exist - so no fill.
        vm.prank(swapper);
        swapOnPool(key, true, -1e20, TickMath.getSqrtPriceAtTick(-key.tickSpacing / 2));

        // intermediate cancels mint each order's fees to the hook independently
        hook.cancelOrder(key, tickA, true, address(this));
        hook.cancelOrder(key, tickB, false, address(this));

        (,,, uint256 c0TotalA, uint256 c1TotalA,) = hook.getOrderInfo(orderAId);
        (,,, uint256 c0TotalB, uint256 c1TotalB,) = hook.getOrderInfo(orderBId);

        // hook's claim balances equal the sum of both orders' currency*Total
        assertEq(
            manager.balanceOf(address(hook), currency0.toId()),
            c0TotalA + c0TotalB,
            "hook currency0 claims should equal sum"
        );
        assertEq(
            manager.balanceOf(address(hook), currency1.toId()),
            c1TotalA + c1TotalB,
            "hook currency1 claims should equal sum"
        );

        // final cancel of order A
        vm.prank(user);
        hook.cancelOrder(key, tickA, true, user);

        // order B's accounting is untouched
        (,,, uint256 c0TotalBAfter, uint256 c1TotalBAfter, uint128 liquidityTotalB) = hook.getOrderInfo(orderBId);
        assertEq(c0TotalBAfter, c0TotalB, "order B currency0Total should be unchanged");
        assertEq(c1TotalBAfter, c1TotalB, "order B currency1Total should be unchanged");
        assertEq(liquidityTotalB, liquidity, "order B liquidity should be unchanged");

        // hook still holds exactly order B's claims
        assertEq(
            manager.balanceOf(address(hook), currency0.toId()),
            c0TotalB,
            "hook should still hold order B's currency0 claims"
        );
        assertEq(
            manager.balanceOf(address(hook), currency1.toId()),
            c1TotalB,
            "hook should still hold order B's currency1 claims"
        );
    }
}
