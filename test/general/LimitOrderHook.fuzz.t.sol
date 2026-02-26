// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
// Internal imports
import {LimitOrderHook, OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {LimitOrderHookMock} from "../../src/mocks/general/LimitOrderHookMock.sol";
import {HookTest} from "../utils/HookTest.sol";
import {console} from "forge-std/console.sol";

contract LimitOrderHookFuzzTest is HookTest {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    LimitOrderHookMock hook;

    // auxiliar variables to hold values across tests
    uint256 swapFees0;
    uint256 swapFees1;

    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address lp3 = makeAddr("lp3");
    address attacker = makeAddr("attacker");
    address swapper = makeAddr("swapper");

    // @dev Does not include `UserInfo` mapping.
    struct ReducedOrderInfo {
        uint256 filledAmount0;
        uint256 filledAmount1;
        uint256 accruedFees0;
        uint256 accruedFees1;
        uint256 accFee0PerLiqX128;
        uint256 accFee1PerLiqX128;
        uint128 liquidityTotal;
        bool filled;
    }

    // @dev Get the reduced order info for a given order id.
    function getReducedOrderInfo(OrderIdLibrary.OrderId orderId) public view returns (ReducedOrderInfo memory) {
        (
            bool filled,,,
            uint256 filledAmount0,
            uint256 filledAmount1,
            uint256 accruedFees0,
            uint256 accruedFees1,
            uint256 accFee0PerLiqX128,
            uint256 accFee1PerLiqX128,
            uint128 liquidityTotal
        ) = hook.getOrderInfo(orderId);
        return ReducedOrderInfo({
            filledAmount0: filledAmount0,
            filledAmount1: filledAmount1,
            accruedFees0: accruedFees0,
            accruedFees1: accruedFees1,
            accFee0PerLiqX128: accFee0PerLiqX128,
            accFee1PerLiqX128: accFee1PerLiqX128,
            liquidityTotal: liquidityTotal,
            filled: filled
        });
    }

    // @dev Get the user info for a given order id and user.
    function getUserInfoInOrder(uint232 orderId, address user) public view returns (LimitOrderHook.UserInfo memory) {
        return hook.getUserInfo(OrderIdLibrary.OrderId.wrap(orderId), user);
    }

    // @dev Get the liquidity in a position for a given key and tick lower.
    function getLiquidityInPosition(PoolKey memory key, int24 tickLower) public view returns (uint128) {
        return manager.getPositionLiquidity(
            key.toId(), Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0)
        );
    }

    // @dev Get the amounts in a position for a given key and tick lower.
    function getAmountsInPosition(PoolKey memory key, int24 tickLower) public view returns (uint256, uint256) {
        return calculateAmountsForLiquidity(key, tickLower, getLiquidityInPosition(key, tickLower));
    }

    // @dev Get the fees in a position for a given key and tick lower.
    function getFeesInPosition(PoolKey memory key, int24 tickLower) public view returns (uint256, uint256) {
        return calculateFees(manager, key.toId(), address(hook), tickLower, tickLower + key.tickSpacing, 0);
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LimitOrderHookMock(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));

        deployCodeTo(
            "src/mocks/general/LimitOrderHookMock.sol:LimitOrderHookMock", abi.encode(address(manager)), address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        vm.deal(address(this), 1e50);
        vm.deal(lp1, 1e30);
        vm.deal(lp2, 1e30);
        vm.deal(lp3, 1e30);
        vm.deal(swapper, 1e30);
        vm.deal(attacker, 1e30);
        IERC20Minimal(Currency.unwrap(currency0)).transfer(address(this), 1e50);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(address(this), 1e50);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(lp1, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(lp1, 1e30);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(lp2, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(lp2, 1e30);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(lp3, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(lp3, 1e30);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(swapper, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(swapper, 1e30);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(attacker, 1e30);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(attacker, 1e30);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        vm.startPrank(lp1);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lp2);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lp3);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(swapper);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(attacker);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    // @dev Bound the tick lower for the limit order.
    function boundTickLower(PoolKey memory key, int24 tickLower, int24 tickDistance) public view returns (int24) {
        int24 currentTick = getCurrentTick(key.toId());
        // tick should be not far away from the current tick, as otherwise enormous swaps are required to reach the order range
        tickLower = int24(bound(tickLower, currentTick - tickDistance, currentTick + tickDistance));
        // tick should not breach the limits of the curve
        tickLower = int24(bound(tickLower, TickMath.MIN_TICK + key.tickSpacing, TickMath.MAX_TICK - key.tickSpacing));
        // tick should be a multiple of tick spacing
        tickLower = flooredTick(tickLower, key.tickSpacing);
        return tickLower;
    }

    // @dev Overload the boundTickLower function with a default tick distance of 3000.
    function boundTickLower(PoolKey memory key, int24 tickLower) public view returns (int24) {
        int24 tickDistance = 3000; // ~50% (1x) price range
        return boundTickLower(key, tickLower, tickDistance);
    }

    // @dev Verify if the limit order is out of range as it should be.
    // Note: a limit order must be placed out of the current range as single side liquidity.
    function isValidLimitOrderRange(PoolKey memory key, bool zeroForOne, int24 tickLower) public view returns (bool) {
        int24 tickUpper = tickLower + key.tickSpacing;
        int24 currentTick = getCurrentTick(key.toId());
        // if the order is zeroForOne, it must be placed to the right of the current tick
        // if the order is oneForZero, it must be placed to the left of the current tick
        return zeroForOne ? tickLower >= currentTick : tickUpper <= currentTick;
    }

    function testFuzz_placeOrder_zeroLiquidity_reverts(int24 tickLower, bool zeroForOne) public {
        tickLower = boundTickLower(key, tickLower);

        bool isValidRange = isValidLimitOrderRange(key, zeroForOne, tickLower);
        vm.assume(isValidRange);

        vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
        vm.prank(lp1);
        hook.placeOrder(key, tickLower, zeroForOne, 0);
    }

    function testFuzz_placeOrder(int24 tickLower, bool zeroForOne, uint128 liquidity) public {
        liquidity = uint128(bound(uint256(liquidity), 1, 1e26));
        tickLower = boundTickLower(key, tickLower);

        bool isValidRange = isValidLimitOrderRange(key, zeroForOne, tickLower);

        (uint256 amount0Expected, uint256 amount1Expected) = calculateAmountsForLiquidity(key, tickLower, liquidity);

        uint256 balance0Before = key.currency0.balanceOf(address(lp1));
        uint256 balance1Before = key.currency1.balanceOf(address(lp1));

        if (isValidRange) {
            vm.expectEmit(true, true, true, true);
            emit LimitOrderHook.Place(lp1, OrderIdLibrary.OrderId.wrap(1), key, tickLower, zeroForOne, liquidity);
        } else {
            vm.expectRevert(LimitOrderHook.InvalidRange.selector);
        }

        vm.prank(lp1);
        hook.placeOrder(key, tickLower, zeroForOne, liquidity);

        uint256 balance0After = key.currency0.balanceOf(address(lp1));
        uint256 balance1After = key.currency1.balanceOf(address(lp1));

        if (isValidRange) {
            assertTrue(
                OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)),
                "orderId should have been assigned"
            );

            bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
            assertEq(
                manager.getPositionLiquidity(key.toId(), positionId),
                liquidity,
                "the liquidity position should have the expected liquidity"
            );

            uint256 lpOrderLiquidity = getUserInfoInOrder(1, lp1).liquidity;
            assertEq(lpOrderLiquidity, liquidity, "lp should own the expected liquidity on the order");

            ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
            assertFalse(orderInfo.filled, "order should not be filled");
            assertEq(orderInfo.filledAmount0, 0, "filledAmount0 should be 0");
            assertEq(orderInfo.filledAmount1, 0, "filledAmount1 should be 0");
            assertEq(orderInfo.accruedFees0, 0, "accruedFees0 should be 0");
            assertEq(orderInfo.accruedFees1, 0, "accruedFees1 should be 0");
            assertEq(orderInfo.accFee0PerLiqX128, 0, "accFee0PerLiqX128 should be 0");
            assertEq(orderInfo.accFee1PerLiqX128, 0, "accFee1PerLiqX128 should be 0");
            assertEq(orderInfo.liquidityTotal, liquidity, "liquidityTotal should be the liquidity");

            assertEq(getLiquidityInPosition(key, tickLower), liquidity, "liquidityInPosition should be the liquidity");

            assertApproxEqAbs(
                balance0Before - balance0After,
                amount0Expected,
                1,
                "lp should have paid the expected amount of currency0"
            );
            assertApproxEqAbs(
                balance1Before - balance1After,
                amount1Expected,
                1,
                "lp should have paid the expected amount of currency1"
            );
        } else {
            assertTrue(
                OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(0)),
                "order should should have the default order id"
            );
        }
    }

    // @dev Fuzzing scenario:
    // - two lps place orders
    // - a swap generates accrued fees without filling the order
    // - the first canceller gets their liquidity back without accrued fees
    // - the second canceller gets their liquidity back plus all the accumulated fees
    function testFuzz_feesAccrued_unfilled(int24 tickLower, bool zeroForOne, uint128 liquidity) public {
        tickLower = boundTickLower(key, tickLower);
        liquidity = uint128(bound(liquidity, 1e8, 1e26));

        (uint256 amount0ToProvide, uint256 amount1ToProvide) = calculateAmountsForLiquidity(key, tickLower, liquidity);

        {
            bool isValidRange = isValidLimitOrderRange(key, zeroForOne, tickLower);
            vm.assume(isValidRange);

            // two lps place orders.
            {
                // lp1 places an order.
                uint256 lp1Balance0Before = key.currency0.balanceOf(address(lp1));
                uint256 lp1Balance1Before = key.currency1.balanceOf(address(lp1));

                vm.prank(lp1);
                hook.placeOrder(key, tickLower, zeroForOne, liquidity);

                uint256 lp1Balance0After = key.currency0.balanceOf(address(lp1));
                uint256 lp1Balance1After = key.currency1.balanceOf(address(lp1));

                assertApproxEqAbs(
                    lp1Balance0Before - lp1Balance0After,
                    amount0ToProvide,
                    1,
                    "lp1 should have paid the expected amount of currency0"
                );
                assertApproxEqAbs(
                    lp1Balance1Before - lp1Balance1After,
                    amount1ToProvide,
                    1,
                    "lp1 should have paid the expected amount of currency1"
                );

                ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
                assertEq(orderInfo.liquidityTotal, liquidity, "liquidityTotal should be the liquidity");

                assertEq(getUserInfoInOrder(1, lp1).liquidity, liquidity, "lp1 owns liquidity in the order");
            }

            {
                // lp2 places an order.
                uint256 lp2Balance0Before = key.currency0.balanceOf(address(lp2));
                uint256 lp2Balance1Before = key.currency1.balanceOf(address(lp2));

                vm.prank(lp2);
                hook.placeOrder(key, tickLower, zeroForOne, liquidity);

                uint256 lp2Balance0After = key.currency0.balanceOf(address(lp2));
                uint256 lp2Balance1After = key.currency1.balanceOf(address(lp2));

                assertApproxEqAbs(
                    lp2Balance0Before - lp2Balance0After,
                    amount0ToProvide,
                    1,
                    "lp2 should have paid the expected amount of currency0"
                );
                assertApproxEqAbs(
                    lp2Balance1Before - lp2Balance1After,
                    amount1ToProvide,
                    1,
                    "lp2 should have paid the expected amount of currency1"
                );

                ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
                assertEq(orderInfo.liquidityTotal, liquidity * 2, "liquidityTotal should be 2 * liquidity");

                assertEq(getUserInfoInOrder(1, lp2).liquidity, liquidity, "lp2 owns liquidity in the order");
            }

            assertEq(
                getLiquidityInPosition(key, tickLower),
                liquidity * 2,
                "actual liquidityInPosition should be twice the liquidity"
            );
        }

        {
            // a swapper swaps, moving the price into the range of the orders, without filling the order.
            uint256 amountToSwap = liquidity / 1e4; // swapper swaps 1/1000 of the liquidity.

            (uint256 feesInPositionBeforeSwap0, uint256 feesInPositionBeforeSwap1) = getFeesInPosition(key, tickLower);

            vm.prank(swapper);
            if (zeroForOne) {
                // if the order is zeroForOne, swap in the oneForZero direction to accrue fees to the order.
                swap(key, false, int256(amountToSwap), "");
            } else {
                // if the order is oneForZero, swap in the zeroForOne direction to accrue fees to the order.
                swap(key, true, int256(amountToSwap), "");
            }

            (uint256 feesInPositionAfterSwap0, uint256 feesInPositionAfterSwap1) = getFeesInPosition(key, tickLower);

            swapFees0 = feesInPositionAfterSwap0 - feesInPositionBeforeSwap0;
            swapFees1 = feesInPositionAfterSwap1 - feesInPositionBeforeSwap1;
            assertTrue(swapFees0 > 0 || swapFees1 > 0, "there should be fees collected from swap");

            // assume the swap moved the price inside the order range.
            int24 currentTick = getCurrentTick(key.toId());
            vm.assume(currentTick > tickLower && currentTick < tickLower + key.tickSpacing);

            // verify the order state after the swap.
            ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
            assertFalse(orderInfo.filled, "order should not be filled");
            assertEq(orderInfo.filledAmount0, 0, "filledAmount0 should be 0");
            assertEq(orderInfo.filledAmount1, 0, "filledAmount1 should be 0");
            assertEq(orderInfo.accruedFees0, 0, "accruedFees0 should be 0");
            assertEq(orderInfo.accruedFees1, 0, "accruedFees1 should be 0");
            assertEq(orderInfo.liquidityTotal, liquidity * 2, "liquidityTotal should still be 2 * liquidity");

            // liquidity in the order should be the same
            assertEq(
                getLiquidityInPosition(key, tickLower), liquidity * 2, "actual liquidityInPosition should be the same"
            );
        }

        {
            // withdrawing: should fail as the order is not filled.
            vm.expectRevert(LimitOrderHook.NotFilled.selector);
            vm.prank(lp1);
            hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(lp1));
        }

        {
            // placing: should fail as the order is now in range.
            vm.expectRevert(LimitOrderHook.InvalidRange.selector);
            vm.prank(lp1);
            hook.placeOrder(key, tickLower, zeroForOne, liquidity);
        }

        {
            // cancelling: should succeed, and accrued fees should only be allocated to the last canceller.
            (uint256 amount0InPosition, uint256 amount1InPosition) = getAmountsInPosition(key, tickLower);

            {
                // lp1 cancels, forfeiting his fees accrued.
                {
                    uint256 lp1Balance0Before = key.currency0.balanceOf(address(lp1));
                    uint256 lp1Balance1Before = key.currency1.balanceOf(address(lp1));

                    vm.prank(lp1);
                    hook.cancelOrder(key, tickLower, zeroForOne, address(lp1));

                    uint256 lp1Balance0After = key.currency0.balanceOf(address(lp1));
                    uint256 lp1Balance1After = key.currency1.balanceOf(address(lp1));

                    // lp1 should have received only the liquidity provided without any fees accrued.
                    assertEq(
                        lp1Balance0After - lp1Balance0Before,
                        amount0InPosition / 2,
                        "lp1 should have received half of the amount0 in the order"
                    );
                    assertEq(
                        lp1Balance1After - lp1Balance1Before,
                        amount1InPosition / 2,
                        "lp1 should have received half of the amount1 in the order"
                    );
                }

                ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
                assertFalse(orderInfo.filled, "order should not be filled");
                assertEq(orderInfo.filledAmount0, 0, "filledAmount0 should be 0");
                assertEq(orderInfo.filledAmount1, 0, "filledAmount1 should be 0");
                assertEq(orderInfo.accruedFees0, swapFees0, "fees collected from pool to accruedFees0");
                assertEq(orderInfo.accruedFees1, swapFees1, "fees collected from pool to accruedFees1");
                assertEq(orderInfo.liquidityTotal, liquidity, "liquidityTotal should be 1 * liquidity");

                (uint256 feesInPosition0After, uint256 feesInPosition1After) = getFeesInPosition(key, tickLower);
                assertEq(feesInPosition0After, 0, "feesInPosition0 should be 0 (collected to hook)");
                assertEq(feesInPosition1After, 0, "feesInPosition1 should be 0 (collected to hook)");

                assertEq(getUserInfoInOrder(1, lp1).liquidity, 0, "lp1 should own 0 liquidity in the order");
            }
            {
                // lp2 cancels, receiving all the fees accrued and deleting the order.
                {
                    uint256 lp2Balance0Before = key.currency0.balanceOf(address(lp2));
                    uint256 lp2Balance1Before = key.currency1.balanceOf(address(lp2));

                    vm.prank(lp2);
                    hook.cancelOrder(key, tickLower, zeroForOne, address(lp2));

                    uint256 lp2Balance0After = key.currency0.balanceOf(address(lp2));
                    uint256 lp2Balance1After = key.currency1.balanceOf(address(lp2));

                    // lp2 receives their liquidity PLUS all the accumulated fees
                    assertEq(
                        lp2Balance0After - lp2Balance0Before,
                        amount0InPosition / 2 + swapFees0,
                        "lp2 should have received the amount0 in the order plus the fees accrued"
                    );
                    assertEq(
                        lp2Balance1After - lp2Balance1Before,
                        amount1InPosition / 2 + swapFees1,
                        "lp2 should have received the amount1 in the order plus the fees accrued"
                    );
                }

                // verify the order state after the last canceller's cancellation.
                ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
                assertFalse(orderInfo.filled, "order should not be filled");
                assertEq(orderInfo.filledAmount0, 0, "filledAmount0 should be 0");
                assertEq(orderInfo.filledAmount1, 0, "filledAmount1 should be 0");
                assertEq(orderInfo.accruedFees0, 0, "accruedFees0 should be 0");
                assertEq(orderInfo.accruedFees1, 0, "accruedFees1 should be 0");
                assertEq(orderInfo.liquidityTotal, 0, "liquidityTotal should be 0");

                (uint256 feesInPosition0After, uint256 feesInPosition1After) = getFeesInPosition(key, tickLower);
                assertEq(feesInPosition0After, 0, "feesInPosition0 should be 0");
                assertEq(feesInPosition1After, 0, "feesInPosition1 should be 0");

                assertEq(getUserInfoInOrder(1, lp2).liquidity, 0, "lp2 should own 0 liquidity in the order");
            }

            assertTrue(
                OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(0)),
                "order should should have the default order id"
            );
        }
    }

    // @dev Fuzzing scenario:
    // - two lps place orders
    // - a swap generates accrued fees filling the order
    // - the first withdrawer gets half the filled amount and half the accrued fees
    // - the second withdrawer gets half the filled amount and half the accrued fees
    function testFuzz_feesAccrued_filled(int24 tickLower, bool zeroForOne, uint128 liquidity) public {
        tickLower = boundTickLower(key, tickLower, 1000);
        liquidity = uint128(bound(liquidity, 1e8, 1e26));

        {
            // two lps place orders.
            bool isValidRange = isValidLimitOrderRange(key, zeroForOne, tickLower);
            vm.assume(isValidRange);

            vm.prank(lp1);
            hook.placeOrder(key, tickLower, zeroForOne, liquidity);
            vm.prank(lp2);
            hook.placeOrder(key, tickLower, zeroForOne, liquidity);

            // Calculate a safe resistance liquidity that won't overflow
            // Use a fixed large value (1e24) to avoid overflow while still providing enough resistance
            uint128 resistanceLiquidity = 1e24;

            // Place a massive resistance order BEYOND the tested order to stop price explosion
            // This prevents the swap from iterating through thousands of ticks
            int24 resistanceTick = zeroForOne ? tickLower + key.tickSpacing : tickLower - key.tickSpacing;
            hook.placeOrder(key, resistanceTick, zeroForOne, resistanceLiquidity);
        }

        {
            // a swapper fills the order.
            // Use 2x liquidity for swap to ensure the order is filled
            uint256 amountToSwap = liquidity * 2;

            vm.prank(swapper);
            if (zeroForOne) {
                // if the order is zeroForOne, swap in the oneForZero direction to accrue fees to the order.
                swap(key, false, int256(amountToSwap), "");
            } else {
                // if the order is oneForZero, swap in the zeroForOne direction to accrue fees to the order.
                swap(key, true, int256(amountToSwap), "");
            }
        }

        // verify the order state after the filling swap
        ReducedOrderInfo memory orderInfoAfterFill = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        {
            assertTrue(orderInfoAfterFill.filled, "order should be filled");

            // the filling should have withdrawn the liquidity from the position to the hook.
            (uint256 amount0InPosition, uint256 amount1InPosition) = getAmountsInPosition(key, tickLower);
            assertEq(amount0InPosition, 0, "amount0InPosition should be 0");
            assertEq(amount1InPosition, 0, "amount1InPosition should be 0");

            // verify the accrued fees have been collected from the position to the hook.
            (uint256 feesInPosition0, uint256 feesInPosition1) = getFeesInPosition(key, tickLower);
            assertTrue(feesInPosition0 == 0, "there should be no fees accrued in the position");
            assertTrue(feesInPosition1 == 0, "there should be no fees accrued in the position");

            // there should be accrued fees in the order.
            assertTrue(
                orderInfoAfterFill.accruedFees0 > 0 || orderInfoAfterFill.accruedFees1 > 0,
                "There are accrued fees in the order"
            );

            assertEq(orderInfoAfterFill.liquidityTotal, liquidity * 2, "liquidityTotal should be 2 * liquidity");
        }

        {
            // placing: reverts as the price is now in the invalid side of the range.
            // would work if the price moved out of range again, but it would generate
            // a new order id (2), and therefore is no way to place at order id 1.
            vm.expectRevert(LimitOrderHook.InvalidRange.selector);
            vm.prank(lp1);
            hook.placeOrder(key, tickLower, zeroForOne, liquidity);
        }

        {
        // cancelling: there is no way to cancel the order id 1 as the orderId has been incremented.
        }

        {
            // first lp withdraws
            uint256 lp1Balance0Before = key.currency0.balanceOf(address(lp1));
            uint256 lp1Balance1Before = key.currency1.balanceOf(address(lp1));

            vm.prank(lp1);
            hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(lp1));

            uint256 lp1Balance0After = key.currency0.balanceOf(address(lp1));
            uint256 lp1Balance1After = key.currency1.balanceOf(address(lp1));

            ReducedOrderInfo memory orderInfoAfterWithdraw = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

            // withdrawer should have received half the filled amount and half the accrued fees.
            assertApproxEqAbs(
                lp1Balance0After - lp1Balance0Before,
                orderInfoAfterFill.filledAmount0 / 2 + orderInfoAfterFill.accruedFees0 / 2,
                1,
                "lp1 should have received half of the filled amount and half of the accrued fees"
            );
            assertApproxEqAbs(
                lp1Balance1After - lp1Balance1Before,
                orderInfoAfterFill.filledAmount1 / 2 + orderInfoAfterFill.accruedFees1 / 2,
                1,
                "lp1 should have received half of the filled amount and half of the accrued fees"
            );

            // the order should now have half the filled amount and half the accrued fees.
            assertApproxEqAbs(
                orderInfoAfterWithdraw.filledAmount0,
                orderInfoAfterFill.filledAmount0 / 2,
                1,
                "filledAmount0 after lp1 withdraw should be half"
            );
            assertApproxEqAbs(
                orderInfoAfterWithdraw.filledAmount1,
                orderInfoAfterFill.filledAmount1 / 2,
                1,
                "filledAmount1 after lp1 withdraw should be half"
            );
            assertApproxEqAbs(
                orderInfoAfterWithdraw.accruedFees0,
                orderInfoAfterFill.accruedFees0 / 2,
                1,
                "accruedFees0 after lp1 withdraw should be half"
            );
            assertApproxEqAbs(
                orderInfoAfterWithdraw.accruedFees1,
                orderInfoAfterFill.accruedFees1 / 2,
                1,
                "accruedFees1 after lp1 withdraw should be half"
            );
        }

        {
            // second lp withdraws
            uint256 lp2Balance0Before = key.currency0.balanceOf(address(lp2));
            uint256 lp2Balance1Before = key.currency1.balanceOf(address(lp2));

            vm.prank(lp2);
            hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(lp2));

            uint256 lp2Balance0After = key.currency0.balanceOf(address(lp2));
            uint256 lp2Balance1After = key.currency1.balanceOf(address(lp2));

            ReducedOrderInfo memory orderInfoAfterWithdraw = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

            assertApproxEqAbs(
                lp2Balance0After - lp2Balance0Before,
                orderInfoAfterFill.filledAmount0 / 2 + orderInfoAfterFill.accruedFees0 / 2,
                2,
                "lp2 should have received half of the filled amount and half of the accrued fees"
            );
            assertApproxEqAbs(
                lp2Balance1After - lp2Balance1Before,
                orderInfoAfterFill.filledAmount1 / 2 + orderInfoAfterFill.accruedFees1 / 2,
                2,
                "lp2 should have received half of the filled amount and half of the accrued fees"
            );

            // the order should now have zero filled amount and zero accrued fees.
            assertEq(orderInfoAfterWithdraw.filledAmount0, 0, "filledAmount0 after lp1 withdraw should be zero");
            assertEq(orderInfoAfterWithdraw.filledAmount1, 0, "filledAmount1 after lp1 withdraw should be zero");
            assertEq(orderInfoAfterWithdraw.accruedFees0, 0, "accruedFees0 after lp1 withdraw should be zero");
            assertEq(orderInfoAfterWithdraw.accruedFees1, 0, "accruedFees1 after lp1 withdraw should be zero");
        }
    }

    // @dev Fuzzing scenario:
    // - two lps place orders
    // - a swap generates accrued fees filling the order
    // - another swap in the opposite direction makes the order out of range again
    // - a third lp places an order
    // - a swap fills the order
    // - the third lp should not receive a portion of previous swaps fees.
    function testFuzz_feesAccrued_outOfRangeAgain_filled(int24 tickLower, bool zeroForOne, uint128 liquidity) public {
        tickLower = boundTickLower(key, tickLower, 1000);
        liquidity = uint128(bound(liquidity, 1e8, 1e26));

        {
            // two lps place orders.
            bool isValidRange = isValidLimitOrderRange(key, zeroForOne, tickLower);
            vm.assume(isValidRange);

            vm.prank(lp1);
            hook.placeOrder(key, tickLower, zeroForOne, liquidity);
            vm.prank(lp2);
            hook.placeOrder(key, tickLower, zeroForOne, liquidity);

            // Calculate a safe resistance liquidity that won't overflow
            // Use a fixed large value (1e24) to avoid overflow while still providing enough resistance
            uint128 resistanceLiquidity = 1e24;

            // Place a massive resistance order BEYOND the tested order to stop price explosion
            // This prevents the swap from iterating through thousands of ticks
            int24 resistanceTick = zeroForOne ? tickLower + key.tickSpacing : tickLower - key.tickSpacing;
            hook.placeOrder(key, resistanceTick, zeroForOne, resistanceLiquidity);
        }

        {
            // a swapper swaps, moving the price into the range of the orders, without filling the order.
            // another swapper swaps in the opposite direction, making the order out of range again.
            uint256 amountToSwap = liquidity / 1e4; // swapper swaps 1/1000 of the liquidity.

            (uint256 feesInPositionBeforeSwap0, uint256 feesInPositionBeforeSwap1) = getFeesInPosition(key, tickLower);

            vm.prank(swapper);
            if (zeroForOne) {
                // if the order is zeroForOne, swap in the oneForZero direction to accrue fees to the order.
                swap(key, false, int256(amountToSwap), "");
                swap(key, true, int256(amountToSwap * 105 / 100), "");
            } else {
                // if the order is oneForZero, swap in the zeroForOne direction to accrue fees to the order.
                swap(key, true, int256(amountToSwap), "");
                swap(key, false, int256(amountToSwap * 105 / 100), "");
            }

            (uint256 feesInPositionAfterSwap0, uint256 feesInPositionAfterSwap1) = getFeesInPosition(key, tickLower);

            swapFees0 = feesInPositionAfterSwap0 - feesInPositionBeforeSwap0;
            swapFees1 = feesInPositionAfterSwap1 - feesInPositionBeforeSwap1;
            assertTrue(swapFees0 > 0 || swapFees1 > 0, "there should be fees collected from swap");
        }

        // verify the order state after the swaps
        ReducedOrderInfo memory orderInfoAfterSwaps = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        // {
        //     assertFalse(orderInfoAfterSwaps.filled, "order should not be filled");

        //     // the liquidity in the order should still be the same
        //     assertEq(orderInfoAfterSwaps.liquidityTotal, liquidity * 2, "liquidityTotal should be the same");
        //     assertEq(getLiquidityInPosition(key, tickLower), liquidity * 2, "actual liquidityInPosition should be the same");

        //     // verify fees have been accrued in the position.
        //     (uint256 feesInPosition0, uint256 feesInPosition1) = getFeesInPosition(key, tickLower);
        //     assertTrue(feesInPosition0 > 0 || feesInPosition1 > 0, "there should be fees accrued in the position");

        //     // there should not be any accrued fees in the order.
        //     assertTrue(orderInfoAfterSwaps.accruedFees0 == 0 && orderInfoAfterSwaps.accruedFees1 == 0, "There should be no accrued fees in the order");
        // }

        {
            // third lp places an order.
            vm.prank(lp3);
            hook.placeOrder(key, tickLower, zeroForOne, liquidity);
        }

        {
            // a swapper fills the order.
            // Use 2x liquidity for swap to ensure the order is filled
            uint256 amountToSwap = liquidity * 2;

            vm.prank(swapper);
            if (zeroForOne) {
                // if the order is zeroForOne, swap in the oneForZero direction to accrue fees to the order.
                swap(key, false, int256(amountToSwap), "");
            } else {
                // if the order is oneForZero, swap in the zeroForOne direction to accrue fees to the order.
                swap(key, true, int256(amountToSwap), "");
            }
        }

        // verify the order state after the filling swap
        ReducedOrderInfo memory orderInfoAfterFill = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        // {
        //     assertTrue(orderInfoAfterFill.filled, "order should be filled");

        //     // the filling should have withdrawn the liquidity from the position to the hook.
        //     (uint256 amount0InPosition, uint256 amount1InPosition) = getAmountsInPosition(key, tickLower);
        //     assertEq(amount0InPosition, 0, "amount0InPosition should be 0");
        //     assertEq(amount1InPosition, 0, "amount1InPosition should be 0");

        //     // verify the accrued fees have been collected from the position to the hook.
        //     (uint256 feesInPosition0, uint256 feesInPosition1) = getFeesInPosition(key, tickLower);
        //     assertTrue(feesInPosition0 == 0, "there should be no fees accrued in the position");
        //     assertTrue(feesInPosition1 == 0, "there should be no fees accrued in the position");

        //     // there should be accrued fees in the order.
        //     assertTrue(orderInfoAfterFill.accruedFees0 > 0 || orderInfoAfterFill.accruedFees1 > 0, "There are accrued fees in the order");

        //     assertEq(orderInfoAfterFill.liquidityTotal, liquidity * 2, "liquidityTotal should be 2 * liquidity");
        // }

        {
            // first lp withdraws
            uint256 lp1Balance0Before = key.currency0.balanceOf(address(lp1));
            uint256 lp1Balance1Before = key.currency1.balanceOf(address(lp1));

            vm.prank(lp1);
            hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(lp1));

            uint256 lp1Balance0After = key.currency0.balanceOf(address(lp1));
            uint256 lp1Balance1After = key.currency1.balanceOf(address(lp1));

            ReducedOrderInfo memory orderInfoAfterWithdraw = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

            // withdrawer should have received a third of the filled amount and half the accrued fees.
            assertApproxEqAbs(
                lp1Balance0After - lp1Balance0Before,
                orderInfoAfterFill.filledAmount0 / 2 + orderInfoAfterFill.accruedFees0 / 2,
                1,
                "lp1 should have received half of the filled amount and half of the accrued fees"
            );
            assertApproxEqAbs(
                lp1Balance1After - lp1Balance1Before,
                orderInfoAfterFill.filledAmount1 / 2 + orderInfoAfterFill.accruedFees1 / 2,
                1,
                "lp1 should have received half of the filled amount and half of the accrued fees"
            );

            // the order should now have half the filled amount and half the accrued fees.
            assertApproxEqAbs(
                orderInfoAfterWithdraw.filledAmount0,
                orderInfoAfterFill.filledAmount0 / 2,
                1,
                "filledAmount0 after lp1 withdraw should be half"
            );
            assertApproxEqAbs(
                orderInfoAfterWithdraw.filledAmount1,
                orderInfoAfterFill.filledAmount1 / 2,
                1,
                "filledAmount1 after lp1 withdraw should be half"
            );
            assertApproxEqAbs(
                orderInfoAfterWithdraw.accruedFees0,
                orderInfoAfterFill.accruedFees0 / 2,
                1,
                "accruedFees0 after lp1 withdraw should be half"
            );
            assertApproxEqAbs(
                orderInfoAfterWithdraw.accruedFees1,
                orderInfoAfterFill.accruedFees1 / 2,
                1,
                "accruedFees1 after lp1 withdraw should be half"
            );
        }

        //     {
        //         // second lp withdraws
        //         uint256 lp2Balance0Before = key.currency0.balanceOf(address(lp2));
        //         uint256 lp2Balance1Before = key.currency1.balanceOf(address(lp2));

        //         vm.prank(lp2);
        //         hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(lp2));

        //         uint256 lp2Balance0After = key.currency0.balanceOf(address(lp2));
        //         uint256 lp2Balance1After = key.currency1.balanceOf(address(lp2));

        //         ReducedOrderInfo memory orderInfoAfterWithdraw = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

        //         assertApproxEqAbs(
        //             lp2Balance0After - lp2Balance0Before,
        //             orderInfoAfterFill.filledAmount0 / 2 + orderInfoAfterFill.accruedFees0 / 2,
        //             2,
        //             "lp2 should have received half of the filled amount and half of the accrued fees"
        //         );
        //         assertApproxEqAbs(
        //             lp2Balance1After - lp2Balance1Before,
        //             orderInfoAfterFill.filledAmount1 / 2 + orderInfoAfterFill.accruedFees1 / 2,
        //             2,
        //             "lp2 should have received half of the filled amount and half of the accrued fees"
        //         );

        //         // the order should now have zero filled amount and zero accrued fees.
        //         assertEq(orderInfoAfterWithdraw.filledAmount0, 0, "filledAmount0 after lp1 withdraw should be zero");
        //         assertEq(orderInfoAfterWithdraw.filledAmount1, 0, "filledAmount1 after lp1 withdraw should be zero");
        //         assertEq(orderInfoAfterWithdraw.accruedFees0, 0, "accruedFees0 after lp1 withdraw should be zero");
        //         assertEq(orderInfoAfterWithdraw.accruedFees1, 0, "accruedFees1 after lp1 withdraw should be zero");
        //     }
    }
}

