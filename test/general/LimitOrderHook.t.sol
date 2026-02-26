// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
// import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
// import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
// import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
// import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
// import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// // Internal imports
// import {LimitOrderHook, OrderIdLibrary} from "src/general/LimitOrderHook.sol";
// import {LimitOrderHookMock} from "../../src/mocks/general/LimitOrderHookMock.sol";
// import {HookTest} from "../utils/HookTest.sol";
// import {console} from "forge-std/console.sol";

// contract LimitOrderHookTest is HookTest {
//     using StateLibrary for IPoolManager;

//     LimitOrderHookMock hook;
//     PoolKey noHookKey;

//     address user = makeAddr("user");
//     address swapper = makeAddr("swapper");
//     address attacker = makeAddr("attacker");

//     int24 tickSpacing;

//     function setUp() public {
//         deployFreshManagerAndRouters();
//         deployMintAndApprove2Currencies();

//         hook = LimitOrderHookMock(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));

//         deployCodeTo(
//             "src/mocks/general/LimitOrderHookMock.sol:LimitOrderHookMock", abi.encode(address(manager)), address(hook)
//         );

//         (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
//         (noHookKey,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

//         tickSpacing = key.tickSpacing;

//         IERC20Minimal(Currency.unwrap(currency0)).transfer(user, 1e30);
//         IERC20Minimal(Currency.unwrap(currency1)).transfer(user, 1e30);
//         IERC20Minimal(Currency.unwrap(currency0)).transfer(swapper, 1e30);
//         IERC20Minimal(Currency.unwrap(currency1)).transfer(swapper, 1e30);
//         IERC20Minimal(Currency.unwrap(currency0)).transfer(attacker, 1e30);
//         IERC20Minimal(Currency.unwrap(currency1)).transfer(attacker, 1e30);

//         IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

//         vm.startPrank(user);
//         IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
//         vm.stopPrank();

//         vm.startPrank(swapper);
//         IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
//         vm.stopPrank();

//         vm.startPrank(attacker);
//         IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
//         IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
//         vm.stopPrank();

//         vm.label(Currency.unwrap(currency0), "currency0");
//         vm.label(Currency.unwrap(currency1), "currency1");
//     }

//         // @dev Does not include `UserInfo` mapping.
//     struct ReducedOrderInfo {
//         uint256 filledAmount0;
//         uint256 filledAmount1;
//         uint256 accruedFees0;
//         uint256 accruedFees1;
//         uint256 accFee0PerLiqX128;
//         uint256 accFee1PerLiqX128;
//         uint128 liquidityTotal;
//         bool filled;
//     }

//     // @dev Get the reduced order info for a given order id.
//     function getReducedOrderInfo(OrderIdLibrary.OrderId orderId) public view returns (ReducedOrderInfo memory) {
//         (
//             bool filled,,,
//             uint256 filledAmount0,
//             uint256 filledAmount1,
//             uint256 accruedFees0,
//             uint256 accruedFees1,
//             uint256 accFee0PerLiqX128,
//             uint256 accFee1PerLiqX128,
//             uint128 liquidityTotal
//         ) = hook.getOrderInfo(orderId);
//         return ReducedOrderInfo({
//             filledAmount0: filledAmount0,
//             filledAmount1: filledAmount1,
//             accruedFees0: accruedFees0,
//             accruedFees1: accruedFees1,
//             accFee0PerLiqX128: accFee0PerLiqX128,
//             accFee1PerLiqX128: accFee1PerLiqX128,
//             liquidityTotal: liquidityTotal,
//             filled: filled
//         });
//     }

//     // @dev Get the user info for a given order id and user.
//     function getUserInfoInOrder(uint232 orderId, address account) public view returns (LimitOrderHook.UserInfo memory) {
//         return hook.getUserInfo(OrderIdLibrary.OrderId.wrap(orderId), account);
//     }

//     // @dev Get the liquidity in a position for a given key and tick lower.
//     function getLiquidityInPosition(PoolKey memory key, int24 tickLower) public view returns (uint128) {
//         return manager.getPositionLiquidity(
//             key.toId(), Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0)
//         );
//     }

//     // @dev Get the amounts in a position for a given key and tick lower.
//     function getAmountsInPosition(PoolKey memory key, int24 tickLower) public view returns (uint256, uint256) {
//         return calculateAmountsForLiquidity(key, tickLower, getLiquidityInPosition(key, tickLower));
//     }

//     // @dev Get the fees in a position for a given key and tick lower.
//     function getFeesInPosition(PoolKey memory key, int24 tickLower) public view returns (uint256, uint256) {
//         return calculateFees(manager, key.toId(), address(hook), tickLower, tickLower + key.tickSpacing, 0);
//     }

//     function test_placeOrder_zeroLiquidity_reverts() public {
//         vm.expectRevert(LimitOrderHook.ZeroLiquidity.selector);
//         hook.placeOrder(key, 0, true, 0);
//     }

//     function test_placeOrder_simple() public {
//         int24 tickLower = 0;
//         bool zeroForOne = true;
//         uint128 liquidity = 1000000;

//         hook.placeOrder(key, tickLower, zeroForOne, liquidity);

//         assertTrue(
//             OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)),
//             "order id should have been increased to 1"
//         );

//         assertEq(getLiquidityInPosition(key, tickLower), liquidity, "liquidity should be added to pool");

//         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
//         assertFalse(orderInfo.filled, "order should not be filled");
//         assertEq(orderInfo.filledAmount0, 0, "filledAmount0 should be 0");
//         assertEq(orderInfo.filledAmount1, 0, "filledAmount1 should be 0");
//         assertEq(orderInfo.accruedFees0, 0, "accruedFees0 should be 0");
//         assertEq(orderInfo.accruedFees1, 0, "accruedFees1 should be 0");
//         assertEq(orderInfo.accFee0PerLiqX128, 0, "accFee0PerLiqX128 should be 0");
//         assertEq(orderInfo.accFee1PerLiqX128, 0, "accFee1PerLiqX128 should be 0");
//         assertEq(orderInfo.liquidityTotal, liquidity, "liquidity total should be accounted");
//     }

//     function test_placeOrder_oneLiquidity_costsTokens() public {
//         uint256 balance0Before = currency0.balanceOf(address(this));
//         uint256 balance1Before = currency1.balanceOf(address(this));
//         hook.placeOrder(key, 60, true, 1);
//         uint256 balance0After = currency0.balanceOf(address(this));
//         uint256 balance1After = currency1.balanceOf(address(this));
//         assertTrue(balance0After < balance0Before || balance1After < balance1Before, "got one liquidity for free");
//     }

//     function test_placeOrder_rightBoundaryOfCurrentRange() public {
//         int24 tickLower = 60;
//         bool zeroForOne = true;
//         uint128 liquidity = 1000000;

//         hook.placeOrder(key, tickLower, zeroForOne, liquidity);

//         assertTrue(
//             OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)),
//             "order id should have been increased to 1"
//         );

//         assertEq(getLiquidityInPosition(key, tickLower), liquidity, "liquidity should be added to pool");

//         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
//         assertEq(orderInfo.liquidityTotal, liquidity, "liquidity total should be accounted");
//     }

//     function test_placeOrder_leftBoundaryOfCurrentRange_zeroForOne() public {
//         int24 tickLower = 0;
//         bool zeroForOne = true;
//         uint128 liquidity = 1000000;

//         hook.placeOrder(key, tickLower, zeroForOne, liquidity);

//         assertTrue(
//             OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)),
//             "order id should have been increased to 1"
//         );

//         assertEq(getLiquidityInPosition(key, tickLower), liquidity, "liquidity should be added to pool");

//         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
//         assertEq(orderInfo.liquidityTotal, liquidity, "liquidity total should be accounted");
//     }

//     function test_placeOrder_crossedRange_reverts() public {
//         vm.expectRevert(LimitOrderHook.InvalidRange.selector);
//         hook.placeOrder(key, -60, true, 1000000);
//     }

//     function test_placeOrder_inRange_reverts() public {
//         // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
//         swapRouter.swap(
//             key,
//             SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 + 1}),
//             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
//             bytes("")
//         );

//         vm.expectRevert(LimitOrderHook.InvalidRange.selector);
//         hook.placeOrder(key, 0, true, 1000000);
//     }

//     function test_placeOrder_leftBoundaryOfCurrentRange_oneForZero() public {
//         int24 tickLower = -60;
//         bool zeroForOne = false;
//         uint128 liquidity = 1000000;

//         hook.placeOrder(key, tickLower, zeroForOne, liquidity);

//         assertTrue(
//             OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)),
//             "order id should have been increased to 1"
//         );

//         assertEq(getLiquidityInPosition(key, tickLower), liquidity, "liquidity should be added to pool");

//         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
//         assertEq(orderInfo.liquidityTotal, liquidity, "liquidity total should be accounted");
//     }

//     function test_placeOrder_crossedRange_oneForZero_reverts() public {
//         vm.expectRevert(LimitOrderHook.InvalidRange.selector);
//         hook.placeOrder(key, 0, false, 1000000);
//     }

//     function test_placeOrder_inRange_oneForZero_reverts() public {
//         // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
//         swapRouter.swap(
//             key,
//             SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1}),
//             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
//             bytes("")
//         );

//         vm.expectRevert(LimitOrderHook.InvalidRange.selector);
//         hook.placeOrder(key, -60, false, 1000000);
//     }

//     function test_placeOrder_multipleLPs() public {
//         int24 tickLower = 60;
//         bool zeroForOne = true;
//         uint128 liquidity = 1000000;

//         hook.placeOrder(key, tickLower, zeroForOne, liquidity);

//         vm.prank(user);
//         hook.placeOrder(key, tickLower, zeroForOne, liquidity);

//         assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)), "order id should have been increased to 1");

//         assertEq(getLiquidityInPosition(key, tickLower), liquidity * 2, "liquidity should be added to pool");

//         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
//         assertEq(orderInfo.liquidityTotal, liquidity * 2, "liquidity total should be accounted");
//         assertEq(getUserInfoInOrder(1, address(this)).liquidity, liquidity);
//         assertEq(getUserInfoInOrder(1, user).liquidity, liquidity);
//     }

//     function test_cancelOrder() public {
//         int24 tickLower = 0;
//         bool zeroForOne = true;
//         uint128 liquidity = 1000000;

//         uint256 balanceBefore = currency0.balanceOf(address(this));

//         hook.placeOrder(key, tickLower, zeroForOne, liquidity);

//         hook.cancelOrder(key, tickLower, zeroForOne, address(this));

//         uint256 balanceAfterCancel = currency0.balanceOf(address(this));

//         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
//         assertFalse(orderInfo.filled, "order should not be filled");
//         assertEq(orderInfo.filledAmount0, 0, "filledAmount0 should be 0");
//         assertEq(orderInfo.filledAmount1, 0, "filledAmount1 should be 0");
//         assertEq(orderInfo.accruedFees0, 0, "accruedFees0 should be 0");
//         assertEq(orderInfo.accruedFees1, 0, "accruedFees1 should be 0");

//         assertApproxEqAbs(balanceBefore, balanceAfterCancel, 1, "lp should recover the cancelled liquidity");
//     }

//     function test_cancelOrder_feesAccrued() public {
//         bool zeroForOne = true;
//         uint128 liquidity = 1e15;

//         // add on hooked
//         hook.placeOrder(key, 0, zeroForOne, liquidity);
//         vm.prank(user);
//         hook.placeOrder(key, 0, zeroForOne, liquidity);

//         // add on unhooked: adding liquidity is equivalent to placing orders
//         modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, int256(uint256(liquidity)), 0);
//         vm.prank(user);
//         modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, int256(uint256(liquidity)), 0);

//         // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
//         vm.startPrank(swapper);
//         swapWithTickLimit(key, false, -1e20, key.tickSpacing / 2);
//         swapWithTickLimit(noHookKey, false, -1e20, key.tickSpacing / 2);
//         vm.stopPrank();

//         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
//         assertFalse(orderInfo.filled, "order should not be filled");
//         assertEq(orderInfo.filledAmount0, 0, "filledAmount0 should be 0");
//         assertEq(orderInfo.filledAmount1, 0, "filledAmount1 should be 0");
//         assertEq(orderInfo.accruedFees0, 0, "accruedFees0 should be 0");
//         assertGe(orderInfo.accruedFees1, 0, "accruedFees1 should be > 0");
//         assertEq(orderInfo.accFee0PerLiqX128, 0, "accFee0PerLiqX128 should be 0");
//         assertEq(orderInfo.accFee1PerLiqX128, 0, "accFee1PerLiqX128 should be 0");
//         assertEq(orderInfo.liquidityTotal, 2 * liquidity, "liquidityTotal should be 2*liquidity");

//         return;

//         // there should be fees accrued to the order position
//         (uint256 feesInPosition0, uint256 feesInPosition1) = getFeesInPosition(key, 0);
//         assertTrue(feesInPosition0 > 0 || feesInPosition1 > 0, "fees should be accrued to the order position");

//         // cancel on hooked
//         int256 balance0BeforeHooked = int256(currency0.balanceOf(address(this)));
//         int256 balance1BeforeHooked = int256(currency1.balanceOf(address(this)));
//         hook.cancelOrder(key, 0, zeroForOne, address(this));
//         int256 balance0AfterCancelHooked = int256(currency0.balanceOf(address(this)));
//         int256 balance1AfterCancelHooked = int256(currency1.balanceOf(address(this)));

//         // cancel on unhooked: removing liquidity is equivalent to canceling orders
//         BalanceDelta removeDelta = modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);

//         (uint256 feesExpected0, uint256 feesExpected1) = getFeesInPosition(noHookKey, 0);
//         assertTrue(feesExpected0 > 0 || feesExpected1 > 0, "fees should be accrued to the order position");

//         ReducedOrderInfo memory orderInfoAfterCancel = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
//         assertFalse(orderInfoAfterCancel.filled, "order should not be filled");
//         assertEq(orderInfoAfterCancel.filledAmount0, 0, "filledAmount0 should be 0");
//         assertEq(orderInfoAfterCancel.filledAmount1, 0, "filledAmount1 should be 0");
//         assertEq(orderInfoAfterCancel.accruedFees0, feesExpected0, "accruedFees0 should be feesExpected0");
//         assertEq(orderInfoAfterCancel.accruedFees1, feesExpected1, "accruedFees1 should be feesExpected1");
//         assertEq(orderInfoAfterCancel.liquidityTotal, liquidity, "liquidityTotal should be liquidity");

//         // canceling the order is the same as removing liquidity, minus the fees accrued to the order (which are in currency total)
//         assertEq(balance0AfterCancelHooked - balance0BeforeHooked, int256(removeDelta.amount0()) - int256(feesExpected0));
//         assertEq(balance1AfterCancelHooked - balance1BeforeHooked, int256(removeDelta.amount1()) - int256(feesExpected1));
//     }

// //     function test_cancelOrder_removingAllLiquidity() public {
// //         bool zeroForOne = true;
// //         uint128 liquidity = 1000000;

// //         // first user places an order
// //         hook.placeOrder(key, 0, zeroForOne, liquidity);

// //         // second user places an order
// //         vm.startPrank(user);
// //         hook.placeOrder(key, 0, zeroForOne, liquidity);
// //         // add liquidity equivalent to two orders
// //         modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, int256(uint256(2 * liquidity)), 0);
// //         vm.stopPrank();

// //         // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
// //         vm.startPrank(swapper);
// //         swap(key, false, -1e20, "");
// //         swap(noHookKey, false, -1e20, "");
// //         vm.stopPrank();

// //         // first user cancels the order
// //         hook.cancelOrder(key, 0, zeroForOne, address(this));

// //         // now second user cancels the order
// //         vm.startPrank(user);
// //         int256 balanceUser0Before = int256(currency0.balanceOf(user));
// //         int256 balanceUser1Before = int256(currency1.balanceOf(user));
// //         hook.cancelOrder(key, 0, zeroForOne, user);
// //         int256 balanceUser0After = int256(currency0.balanceOf(user));
// //         int256 balanceUser1After = int256(currency1.balanceOf(user));
// //         vm.stopPrank();

// //         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));
// //         assertFalse(orderInfo.filled, "order should not be filled");
// //         assertEq(orderInfo.liquidityTotal, 0, "liquidityTotal should be liquidity");
// //         assertEq(orderInfo.filledAmount0, 0, "filledAmount0 should be 0");
// //         assertEq(orderInfo.filledAmount1, 0, "filledAmount1 should be 0");
// //         assertEq(orderInfo.accruedFees0, 0, "accruedFees0 should be 0");
// //         assertEq(orderInfo.accruedFees1, 0, "accruedFees1 should be 0");
// //         assertEq(orderInfo.accFee0PerLiqX128, 0, "accFee0PerLiqX128 should be 0");
// //         assertEq(orderInfo.accFee1PerLiqX128, 0, "accFee1PerLiqX128 should be 0");

// //         // cancel the order is the same as remove liquidity from the pool in the range (0, tickSpacing)
// //         vm.startPrank(user);
// //         (uint256 feesExpected0, uint256 feesExpected1) =
// //             calculateFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), 0, key.tickSpacing, 0);
// //         BalanceDelta delta = modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);
// //         vm.stopPrank();

// //         assertTrue(feesExpected0 > 0 || feesExpected1 > 0);

// //         // all fees accrued go to the last user to cancel the order
// //         assertEq(balanceUser0After - balanceUser0Before, int256(delta.amount0()));
// //         assertEq(balanceUser1After - balanceUser1Before, int256(delta.amount1()));
// //     }

// //     function test_placeOrder_feesAccrued() public {
// //         bool zeroForOne = true;
// //         uint128 liquidity = 1000000;

// //         hook.placeOrder(key, 0, zeroForOne, liquidity);

// //         //place order is the same as add liquidity to the pool in the range (0, tickSpacing)
// //         vm.startPrank(user);
// //         hook.placeOrder(key, 0, zeroForOne, liquidity);

// //         // add liquidity equivalent to two orders
// //         modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, int256(uint256(2 * liquidity)), 0);
// //         vm.stopPrank();

// //         // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
// //         vm.startPrank(swapper);
// //         swap(key, false, -1e20, "");
// //         swap(noHookKey, false, -1e20, "");

// //         // swap outside of the range (0, tickSpacing) without filling the order to be able to place orders again
// //         swap(noHookKey, true, -1e15, "");
// //         swap(key, true, -1e15, "");

// //         vm.stopPrank();

// //         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertFalse(orderInfo.filled, "order should not be filled");
// //         assertEq(orderInfo.filledAmount0, 0, "filledAmount0 should be 0");
// //         assertEq(orderInfo.filledAmount1, 0, "filledAmount1 should be 0");
// //         assertEq(orderInfo.liquidityTotal, 2 * liquidity, "liquidityTotal should be 2*liquidity");

// //         int256 balance0Before = int256(currency0.balanceOf(address(this)));
// //         int256 balance1Before = int256(currency1.balanceOf(address(this)));
// //         hook.placeOrder(key, 0, zeroForOne, liquidity);
// //         int256 balance0AfterPlace = int256(currency0.balanceOf(address(this)));
// //         int256 balance1AfterPlace = int256(currency1.balanceOf(address(this)));

// //         // place the order is the same as add liquidity to the pool in the range (0, tickSpacing)

// //         vm.startPrank(user);
// //         (uint256 feesExpected0, uint256 feesExpected1) =
// //             calculateFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), 0, key.tickSpacing, 0);
// //         BalanceDelta delta = modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, int256(uint256(liquidity)), 0);
// //         vm.stopPrank();
// //         ReducedOrderInfo memory orderInfoAfterPlace = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertFalse(orderInfoAfterPlace.filled, "order should not be filled");
// //         assertEq(orderInfoAfterPlace.liquidityTotal, 3 * liquidity, "liquidityTotal should be 3*liquidity");

// //         assertEq(orderInfoAfterPlace.filledAmount0, feesExpected0, "filledAmount0 should be feesExpected0");
// //         assertEq(orderInfoAfterPlace.filledAmount1, feesExpected1, "filledAmount1 should be feesExpected1");

// //         assertTrue(feesExpected0 > 0 || feesExpected1 > 0, "fees should be accrued");

// //         // placing the order is the same as adding liquidity, plus the fees accrued to the order (which are in currency total)
// //         assertEq(
// //             balance0AfterPlace - balance0Before,
// //             int256(delta.amount0()) - int256(currency0Total),
// //             "fees were not held in currency0Total"
// //         );
// //         assertEq(
// //             balance1AfterPlace - balance1Before,
// //             int256(delta.amount1()) - int256(currency1Total),
// //             "fees were not held in currency1Total"
// //         );
// //     }

// //     function test_withdraw_multipleLPs() public {
// //         int24 tickLower = 0;
// //         bool zeroForOne = true;
// //         uint128 liquidity = 1000000;

// //         hook.placeOrder(key, tickLower, zeroForOne, liquidity);

// //         currency0.transfer(user, 1e18);
// //         currency1.transfer(user, 1e18);

// //         vm.startPrank(user);
// //         hook.placeOrder(key, tickLower, zeroForOne, liquidity);
// //         vm.stopPrank();

// //         assertTrue(OrderIdLibrary.equals(hook.getOrderId(key, tickLower, zeroForOne), OrderIdLibrary.OrderId.wrap(1)));

// //         bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
// //         assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity * 2);

// //         swapRouter.swap(
// //             key,
// //             SwapParams({
// //                 zeroForOne: false,
// //                 amountSpecified: -1e18,
// //                 sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower + key.tickSpacing)
// //             }),
// //             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
// //             ZERO_BYTES
// //         );

// //         (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertTrue(filled, "order should be filled");
// //         assertEq(currency0Total, 0, "wrong amount of currency0");
// //         assertEq(currency1Total, 2 * (2996 + 17), "wrong amount of currency1");

// //         vm.startPrank(user);
// //         hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
// //         vm.stopPrank();

// //         (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertTrue(filled, "order should be filled");
// //         assertEq(currency0Total, 0, "wrong amount of currency0");
// //         assertEq(currency1Total, 2996 + 17, "wrong amount of currency1");

// //         hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));

// //         (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertTrue(filled, "order should be filled");
// //         assertEq(currency0Total, 0, "wrong amount of currency0");
// //         assertEq(currency1Total, 0, "wrong amount of currency1");
// //     }

// //     function test_withdraw_noUnderflowAfterEarlierWithdrawals() public {
// //         uint256 FEES_0 = 90198636691739;
// //         uint256 FEES_1 = 90334029396399;
// //         uint256 FILL_SWAP_FEES = 27120548209305;
// //         uint256 FILL_AMOUNT_1 = 9013062188225776;

// //         int24 tickLower = 0;
// //         uint128 liquidity = 1e18;

// //         OrderIdLibrary.OrderId orderId = OrderIdLibrary.OrderId.wrap(1);

// //         {
// //             // First participant places order.
// //             hook.placeOrder(key, tickLower, true, liquidity);

// //             {
// //                 (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(orderId);
// //                 (
// //                     ,
// //                     uint256 filledAmount0,
// //                     uint256 filledAmount1,
// //                     uint256 accruedFees0,
// //                     uint256 accruedFees1,
// //                     uint256 accFee0PerLiqX128,
// //                     uint256 accFee1PerLiqX128,
// //                 ) = hook.getExtendedtOrderInfo(orderId);

// //                 console.log("--------------------------------");
// //                 console.log("PLACED ORDER");
// //                 console.log("liquidityTotal", liquidityTotal);
// //                 console.log("filledAmount0", filledAmount0);
// //                 console.log("filledAmount1", filledAmount1);
// //                 console.log("accruedFees0", accruedFees0);
// //                 console.log("accruedFees1", accruedFees1);
// //                 console.log("accFee0PerLiqX128", accFee0PerLiqX128);
// //                 console.log("accFee1PerLiqX128", accFee1PerLiqX128);
// //                 assertEq(filled, false, "order should not be filled");
// //                 assertEq(liquidityTotal, 1e18, "liquidityTotal should be 1e18");
// //                 assertEq(filledAmount0, 0, "filledAmount0 should be 0");
// //                 assertEq(filledAmount1, 0, "filledAmount1 should be 0");
// //                 assertEq(accruedFees0, 0, "accruedFees0 should be 0");
// //                 assertEq(accruedFees1, 0, "accruedFees1 should be 0");
// //                 assertEq(accFee0PerLiqX128, 0, "accFee0PerLiqX128 should be 0");
// //                 assertEq(accFee1PerLiqX128, 0, "accFee1PerLiqX128 should be 0");
// //             }
// //             {
// //                 (uint256 accruedFees0InPool, uint256 accruedFees1InPool) =
// //                     calculateFees(manager, key.toId(), address(hook), tickLower, tickLower + key.tickSpacing, 0);
// //                 console.log("accruedFees0InPool", accruedFees0InPool);
// //                 console.log("accruedFees1InPool", accruedFees1InPool);
// //                 assertEq(accruedFees0InPool, 0, "accruedFees0InPool should be 0");
// //                 assertEq(accruedFees1InPool, 0, "accruedFees1InPool should be 0");
// //             }
// //         }

// //         {
// //             // Accrue substantial fees before the next participants join.
// //             vm.startPrank(swapper);
// //             for (uint256 i = 0; i < 20; ++i) {
// //                 swapOnPool(key, false, -5e20, TickMath.getSqrtPriceAtTick(tickSpacing / 2));
// //                 swapOnPool(key, true, -5e20, TickMath.getSqrtPriceAtTick(-tickSpacing));
// //             }
// //             vm.stopPrank();

// //             {
// //                 (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(orderId);
// //                 (
// //                     ,
// //                     uint256 filledAmount0,
// //                     uint256 filledAmount1,
// //                     uint256 accruedFees0,
// //                     uint256 accruedFees1,
// //                     uint256 accFee0PerLiqX128,
// //                     uint256 accFee1PerLiqX128,
// //                 ) = hook.getExtendedtOrderInfo(orderId);
// //                 console.log("--------------------------------");
// //                 console.log("GENERATED FEES");
// //                 console.log("liquidityTotal", liquidityTotal);
// //                 console.log("filledAmount0", filledAmount0);
// //                 console.log("filledAmount1", filledAmount1);
// //                 console.log("accruedFees0", accruedFees0);
// //                 console.log("accruedFees1", accruedFees1);
// //                 console.log("accFee0PerLiqX128", accFee0PerLiqX128);
// //                 console.log("accFee1PerLiqX128", accFee1PerLiqX128);
// //                 assertEq(filled, false, "order should not be filled");
// //                 assertEq(liquidityTotal, 1e18, "liquidityTotal should be 1e18");
// //                 assertEq(filledAmount0, 0, "filledAmount0 should be 0");
// //                 assertEq(filledAmount1, 0, "filledAmount1 should be 0");
// //                 assertEq(accruedFees0, 0, "accruedFees0 should be 0");
// //                 assertEq(accruedFees1, 0, "accruedFees1 should be 0");
// //                 assertEq(accFee0PerLiqX128, 0, "accFee0PerLiqX128 should be 0");
// //                 assertEq(accFee1PerLiqX128, 0, "accFee1PerLiqX128 should be 0");
// //             }
// //             {
// //                 (uint256 accruedFees0InPool, uint256 accruedFees1InPool) =
// //                     calculateFees(manager, key.toId(), address(hook), tickLower, tickLower + key.tickSpacing, 0);
// //                 console.log("accruedFees0InPool", accruedFees0InPool);
// //                 console.log("accruedFees1InPool", accruedFees1InPool);
// //                 assertEq(accruedFees0InPool, FEES_0, "accruedFees0InPool should be FEES_0");
// //                 assertEq(accruedFees1InPool, FEES_1, "accruedFees1InPool should be FEES_1");
// //             }
// //         }

// //         {
// //             // Second participant places order.
// //             vm.prank(user);
// //             hook.placeOrder(key, tickLower, true, liquidity);

// //             {
// //                 (filled,,,,, liquidityTotal) = hook.getOrderInfo(orderId);
// //                 (
// //                     ,
// //                     uint256 filledAmount0,
// //                     uint256 filledAmount1,
// //                     uint256 accruedFees0,
// //                     uint256 accruedFees1,
// //                     uint256 accFee0PerLiqX128,
// //                     uint256 accFee1PerLiqX128,
// //                 ) = hook.getExtendedtOrderInfo(orderId);
// //                 console.log("--------------------------------");
// //                 console.log("ADDED LIQUIDITY 2");
// //                 console.log("liquidityTotal", liquidityTotal);
// //                 console.log("filledAmount0", filledAmount0);
// //                 console.log("filledAmount1", filledAmount1);
// //                 console.log("accruedFees0", accruedFees0);
// //                 console.log("accruedFees1", accruedFees1);
// //                 console.log("accFee0PerLiqX128", accFee0PerLiqX128);
// //                 console.log("accFee1PerLiqX128", accFee1PerLiqX128);
// //                 assertEq(filled, false, "order should not be filled");
// //                 assertEq(liquidityTotal, 2e18, "liquidityTotal should be 3e18");
// //                 assertEq(filledAmount0, 0, "filledAmount0 should be 0");
// //                 assertEq(filledAmount1, 0, "filledAmount1 should be 0");
// //                 assertEq(accruedFees0, FEES_0, "accruedFees0 should be 0");
// //                 assertEq(accruedFees1, FEES_1, "accruedFees1 should be 0");
// //             }

// //             {
// //                 (uint256 accruedFees0InPool, uint256 accruedFees1InPool) =
// //                     calculateFees(manager, key.toId(), address(user), tickLower, tickLower + key.tickSpacing, 0);
// //                 console.log("accruedFees0InPool", accruedFees0InPool);
// //                 console.log("accruedFees1InPool", accruedFees1InPool);
// //                 assertEq(accruedFees0InPool, 0, "accruedFees0InPool should be 0");
// //                 assertEq(accruedFees1InPool, 0, "accruedFees1InPool should be 0");
// //             }
// //         }

// //         {
// //             // Third participant places order.
// //             vm.prank(attacker);
// //             hook.placeOrder(key, tickLower, true, liquidity);

// //             {
// //                 (filled,,,,, liquidityTotal) = hook.getOrderInfo(orderId);
// //                 (
// //                     ,
// //                     uint256 filledAmount0,
// //                     uint256 filledAmount1,
// //                     uint256 accruedFees0,
// //                     uint256 accruedFees1,
// //                     uint256 accFee0PerLiqX128,
// //                     uint256 accFee1PerLiqX128,
// //                 ) = hook.getExtendedtOrderInfo(orderId);
// //                 console.log("--------------------------------");
// //                 console.log("ADDED LIQUIDITY 3");
// //                 console.log("liquidityTotal", liquidityTotal);
// //                 console.log("filledAmount0", filledAmount0);
// //                 console.log("filledAmount1", filledAmount1);
// //                 console.log("accruedFees0", accruedFees0);
// //                 console.log("accruedFees1", accruedFees1);
// //                 console.log("accFee0PerLiqX128", accFee0PerLiqX128);
// //                 console.log("accFee1PerLiqX128", accFee1PerLiqX128);
// //                 assertEq(filled, false, "order should not be filled");
// //                 assertEq(liquidityTotal, 3e18, "liquidityTotal should be 3e18");
// //                 assertEq(filledAmount0, 0, "filledAmount0 should be 0");
// //                 assertEq(filledAmount1, 0, "filledAmount1 should be 0");
// //                 assertEq(accruedFees0, FEES_0, "accruedFees0 should be 0");
// //                 assertEq(accruedFees1, FEES_1, "accruedFees1 should be 0");
// //             }

// //             (uint256 accruedFees0InPool, uint256 accruedFees1InPool) =
// //                 calculateFees(manager, key.toId(), address(user), tickLower, tickLower + key.tickSpacing, 0);
// //             console.log("accruedFees0InPool", accruedFees0InPool);
// //             console.log("accruedFees1InPool", accruedFees1InPool);
// //             assertEq(accruedFees0InPool, 0, "accruedFees0InPool should be 0");
// //             assertEq(accruedFees1InPool, 0, "accruedFees1InPool should be 0");
// //         }

// //         {
// //             // Fill the order.
// //             vm.prank(swapper);
// //             swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(2 * tickSpacing));

// //             {
// //                 (filled,,,,, liquidityTotal) = hook.getOrderInfo(orderId);
// //                 (
// //                     ,
// //                     uint256 filledAmount0,
// //                     uint256 filledAmount1,
// //                     uint256 accruedFees0,
// //                     uint256 accruedFees1,
// //                     uint256 accFee0PerLiqX128,
// //                     uint256 accFee1PerLiqX128,
// //                 ) = hook.getExtendedtOrderInfo(orderId);
// //                 console.log("--------------------------------");
// //                 console.log("FILLED ORDER");
// //                 console.log("liquidityTotal", liquidityTotal);
// //                 console.log("filledAmount0", filledAmount0);
// //                 console.log("filledAmount1", filledAmount1);
// //                 console.log("accruedFees0", accruedFees0);
// //                 console.log("accruedFees1", accruedFees1);
// //                 console.log("accFee0PerLiqX128", accFee0PerLiqX128);
// //                 console.log("accFee1PerLiqX128", accFee1PerLiqX128);
// //                 assertEq(filled, true, "order should be filled");
// //                 assertEq(liquidityTotal, 3e18, "liquidityTotal should be 3e18");
// //                 assertEq(filledAmount0, 0, "filledAmount0 should be 0");
// //                 assertEq(filledAmount1, FILL_AMOUNT_1, "filledAmount1 should be FILL_AMOUNT_1");
// //                 assertEq(accruedFees0, FEES_0, "accruedFees0 should be FEES_0");
// //                 assertEq(accruedFees1, FEES_1 + FILL_SWAP_FEES, "accruedFees1 should be FEES_1 + FILL_SWAP_FEES");
// //             }
// //             {
// //                 (uint256 accruedFees0InPool, uint256 accruedFees1InPool) =
// //                     calculateFees(manager, key.toId(), address(user), tickLower, tickLower + key.tickSpacing, 0);
// //                 console.log("accruedFees0InPool", accruedFees0InPool);
// //                 console.log("accruedFees1InPool", accruedFees1InPool);
// //                 assertEq(accruedFees0InPool, 0, "accruedFees0InPool should be 0");
// //                 assertEq(accruedFees1InPool, 0, "accruedFees1InPool should be 0");
// //             }
// //         }

// //         {
// //             // First participant withdraws.
// //             hook.withdraw(orderId, address(this));
// //             (filled,,,,, liquidityTotal) = hook.getOrderInfo(orderId);
// //             (
// //                 ,
// //                 uint256 filledAmount0,
// //                 uint256 filledAmount1,
// //                 uint256 accruedFees0,
// //                 uint256 accruedFees1,
// //                 uint256 accFee0PerLiqX128,
// //                 uint256 accFee1PerLiqX128,
// //             ) = hook.getExtendedtOrderInfo(orderId);
// //             console.log("--------------------------------");
// //             console.log("WITHDRAW 1");
// //             console.log("liquidityTotal", liquidityTotal);
// //             console.log("filledAmount0", filledAmount0);
// //             console.log("filledAmount1", filledAmount1);
// //             console.log("accruedFees0", accruedFees0);
// //             console.log("accruedFees1", accruedFees1);
// //             console.log("accFee0PerLiqX128", accFee0PerLiqX128);
// //             console.log("accFee1PerLiqX128", accFee1PerLiqX128);
// //             assertEq(filled, true, "order should be filled");
// //             assertEq(liquidityTotal, 2e18, "liquidityTotal should be 2e18");
// //             assertEq(filledAmount0, 0, "filledAmount0 should be 0");
// //             assertApproxEqAbs(
// //                 filledAmount1, FILL_AMOUNT_1 * 2 / 3, 1, "filledAmount1 should be (FILL_AMOUNT_1 / 3) * 2"
// //             );
// //             assertApproxEqAbs(accruedFees0, 0, 1, "accruedFees0 should be 0");
// //             assertApproxEqAbs(
// //                 accruedFees1, FILL_SWAP_FEES * 2 / 3, 1, "accruedFees1 should be (FILL_SWAP_FEES / 3) * 2"
// //             );
// //         }

// //         {
// //             // Second participant withdraws.
// //             vm.prank(user);
// //             hook.withdraw(orderId, user);

// //             (filled,,,,, liquidityTotal) = hook.getOrderInfo(orderId);
// //             (
// //                 ,
// //                 uint256 filledAmount0,
// //                 uint256 filledAmount1,
// //                 uint256 accruedFees0,
// //                 uint256 accruedFees1,
// //                 uint256 accFee0PerLiqX128,
// //                 uint256 accFee1PerLiqX128,
// //             ) = hook.getExtendedtOrderInfo(orderId);
// //             console.log("--------------------------------");
// //             console.log("WITHDRAW 2");
// //             console.log("liquidityTotal", liquidityTotal);
// //             console.log("filledAmount0", filledAmount0);
// //             console.log("filledAmount1", filledAmount1);
// //             console.log("accruedFees0", accruedFees0);
// //             console.log("accruedFees1", accruedFees1);
// //             console.log("accFee0PerLiqX128", accFee0PerLiqX128);
// //             console.log("accFee1PerLiqX128", accFee1PerLiqX128);
// //             assertEq(filled, true, "order should be filled");
// //             assertEq(liquidityTotal, 1e18, "liquidityTotal should be 1e18");
// //             assertEq(filledAmount0, 0, "filledAmount0 should be 0");
// //             assertApproxEqAbs(filledAmount1, FILL_AMOUNT_1 * 1 / 3, 2, "filledAmount1 should be (FILL_AMOUNT_1 / 3)");
// //             assertApproxEqAbs(accruedFees0, 0, 2, "accruedFees0 should be 0");
// //             assertApproxEqAbs(accruedFees1, FILL_SWAP_FEES * 1 / 3, 2, "accruedFees1 should be (FILL_SWAP_FEES / 3)");
// //         }

// //         {
// //             // Third participant withdraws.
// //             vm.prank(attacker);
// //             hook.withdraw(orderId, attacker);

// //             (filled,,,,, liquidityTotal) = hook.getOrderInfo(orderId);
// //             (
// //                 ,
// //                 uint256 filledAmount0,
// //                 uint256 filledAmount1,
// //                 uint256 accruedFees0,
// //                 uint256 accruedFees1,
// //                 uint256 accFee0PerLiqX128,
// //                 uint256 accFee1PerLiqX128,
// //             ) = hook.getExtendedtOrderInfo(orderId);
// //             console.log("--------------------------------");
// //             console.log("WITHDRAW 3");
// //             console.log("liquidityTotal", liquidityTotal);
// //             console.log("filledAmount0", filledAmount0);
// //             console.log("filledAmount1", filledAmount1);
// //             console.log("accruedFees0", accruedFees0);
// //             console.log("accruedFees1", accruedFees1);
// //             assertEq(filled, true, "order should be filled");
// //             assertEq(liquidityTotal, 0, "liquidityTotal should be 0");
// //             assertEq(filledAmount0, 0, "filledAmount0 should be 0");
// //             assertEq(filledAmount1, 0, "filledAmount1 should be 0");
// //             assertEq(accruedFees0, 0, "accruedFees0 should be 0");
// //             assertEq(accruedFees1, 0, "accruedFees1 should be 0");
// //         }
// //     }

// //     function test_withdraw_feesAccruedFromCancel() public {
// //         bool zeroForOne = true;
// //         uint128 liquidity = 1000000;

// //         // first user places an order
// //         hook.placeOrder(key, 0, zeroForOne, liquidity);

// //         // second user places an order
// //         vm.startPrank(user);
// //         hook.placeOrder(key, 0, zeroForOne, liquidity);
// //         // add liquidity equivalent to two orders
// //         modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, int256(uint256(2 * liquidity)), 0);
// //         vm.stopPrank();

// //         // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
// //         vm.startPrank(swapper);
// //         swap(key, false, -1e20, "");
// //         swap(noHookKey, false, -1e20, "");
// //         vm.stopPrank();

// //         // first user cancels the order
// //         hook.cancelOrder(key, 0, zeroForOne, address(this));

// //         vm.startPrank(user);
// //         (uint256 initialFeesExpected0, uint256 initialFeesExpected1) =
// //             calculateFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), 0, key.tickSpacing, 0);
// //         BalanceDelta delta = modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);
// //         vm.stopPrank();

// //         assertTrue(initialFeesExpected0 > 0 || initialFeesExpected1 > 0, "fees should be accrued");

// //         ReducedOrderInfo memory orderInfo = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertFalse(orderInfo.filled, "order should not be filled");
// //         assertEq(orderInfo.liquidityTotal, liquidity, "liquidityTotal should be liquidity");
// //         assertEq(orderInfo.filledAmount0, uint256(uint128(initialFeesExpected0)), "filledAmount0 should be feesExpected0");
// //         assertEq(orderInfo.filledAmount1, uint256(uint128(initialFeesExpected1)), "filledAmount1 should be feesExpected1");

// //         // this swap should fill the order, cross the range (0, tickSpacing)
// //         vm.startPrank(swapper);
// //         swap(key, false, -1e20, "");
// //         swap(noHookKey, false, -1e20, "");
// //         vm.stopPrank();

// //         // second user withdraws the order
// //         vm.startPrank(user);
// //         int256 balanceUser0Before = int256(currency0.balanceOf(user));
// //         int256 balanceUser1Before = int256(currency1.balanceOf(user));
// //         hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
// //         int256 balanceUser0After = int256(currency0.balanceOf(user));
// //         int256 balanceUser1After = int256(currency1.balanceOf(user));
// //         vm.stopPrank();

// //         ReducedOrderInfo memory orderInfoAfterWithdraw = getReducedOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertTrue(orderInfoAfterWithdraw.filled, "order should be filled");
// //         assertApproxEqAbs(orderInfoAfterWithdraw.filledAmount0, 0, 1, "filledAmount0 should be 0");
// //         assertApproxEqAbs(orderInfoAfterWithdraw.filledAmount1, 0, 1, "filledAmount1 should be 0");
// //         assertApproxEqAbs(orderInfoAfterWithdraw.liquidityTotal, 0, 1, "liquidityTotal should be 0");

// //         // cancel the order is the same as remove liquidity from the pool in the range (0, tickSpacing)
// //         vm.startPrank(user);
// //         delta = modifyPoolLiquidity(noHookKey, 0, key.tickSpacing, -int256(uint256(liquidity)), 0);
// //         vm.stopPrank();

// //         // the fees are added to the balance of the user who withdraws the order
// //         assertApproxEqAbs(
// //             balanceUser0After - balanceUser0Before,
// //             int256(delta.amount0()) + int256(initialFeesExpected0),
// //             1,
// //             "withdrawer should have received delta + fees"
// //         );
// //         assertApproxEqAbs(
// //             balanceUser1After - balanceUser1Before,
// //             int256(delta.amount1()) + int256(initialFeesExpected1),
// //             1,
// //             "withdrawer should have received delta + fees"
// //         );
// //     }

// //     function test_withdraw_feesAccruedJIT() public {
// //         // some user places an order
// //         hook.placeOrder(key, 0, true, 1e15);

// //         // user places the same order as the first user
// //         vm.startPrank(user);
// //         hook.placeOrder(key, 0, true, 1e15);
// //         // add liquidity equivalent to 2 orders
// //         modifyPoolLiquidityNoChecks(noHookKey, 0, key.tickSpacing, int256(uint256(2 * 1e15)), 0);
// //         vm.stopPrank();

// //         vm.startPrank(swapper);
// //         // this swap should accrue fees to the order, since tick is in range (0, tickSpacing)
// //         swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(tickSpacing / 2));
// //         swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(tickSpacing / 2));

// //         // swap outside of the range (0, tickSpacing) without filling the order to be able to place orders again
// //         swapOnPool(key, true, -1e15, TickMath.getSqrtPriceAtTick(-tickSpacing));
// //         swapOnPool(noHookKey, true, -1e15, TickMath.getSqrtPriceAtTick(-tickSpacing));
// //         vm.stopPrank();

// //         // some user cancels the order, which accrues fees to the order
// //         hook.cancelOrder(key, 0, true, address(this));

// //         // attacker places the same order as the first user
// //         vm.startPrank(attacker);
// //         hook.placeOrder(key, 0, true, 1e15);
// //         vm.stopPrank();

// //         // add liquidity to be equivalent as placing the order
// //         vm.startPrank(user);
// //         (uint256 initialFeesExpected0, uint256 initialFeesExpected1) =
// //             calculateFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), 0, tickSpacing, 0);
// //         modifyPoolLiquidityNoChecks(noHookKey, 0, tickSpacing, int256(uint256(1e15)), 0);
// //         vm.stopPrank();

// //         vm.startPrank(user);
// //         BalanceDelta delta = modifyPoolLiquidityNoChecks(noHookKey, 0, tickSpacing, -int256(uint256(1e15)), 0);
// //         vm.stopPrank();

// //         assertTrue(initialFeesExpected0 > 0 || initialFeesExpected1 > 0, "fees should be accrued");

// //         (filled,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertFalse(filled, "order should not be filled");
// //         assertEq(liquidityTotal, 1e15 * 2, "liquidityTotal should be 2 * liquidity");
// //         assertApproxEqAbs(
// //             currency0Total, uint256(uint128(initialFeesExpected0)), 1, "currency0Total should be the fees accrued"
// //         );
// //         assertApproxEqAbs(
// //             currency1Total, uint256(uint128(initialFeesExpected1)), 1, "currency1Total should be the fees accrued"
// //         );

// //         // this swap should fill the order, cross the range (0, tickSpacing)
// //         vm.startPrank(swapper);
// //         swapOnPool(key, false, -1e20, TickMath.getSqrtPriceAtTick(2 * tickSpacing));
// //         swapOnPool(noHookKey, false, -1e20, TickMath.getSqrtPriceAtTick(2 * tickSpacing));
// //         vm.stopPrank();

// //         vm.startPrank(user);
// //         delta = modifyPoolLiquidityNoChecks(noHookKey, 0, tickSpacing, -int256(uint256(2 * 1e15)), 0);
// //         vm.stopPrank();

// //         (,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         // currency on the hook should be delta
// //         assertEq(
// //             currency0Total,
// //             uint256(uint128(delta.amount0())) + uint256(uint128(initialFeesExpected0)),
// //             "currency0Total should be the delta.amount0() + initialFeesExpected0"
// //         );
// //         assertEq(
// //             currency1Total,
// //             uint256(uint128(delta.amount1())) + uint256(uint128(initialFeesExpected1)),
// //             "currency1Total should be the delta.amount1() + initialFeesExpected1"
// //         );

// //         // attacker withdraws the order
// //         vm.startPrank(attacker);
// //         int256 balanceAttacker0Before = int256(currency0.balanceOf(attacker));
// //         int256 balanceAttacker1Before = int256(currency1.balanceOf(attacker));
// //         hook.withdraw(OrderIdLibrary.OrderId.wrap(1), attacker);
// //         int256 balanceAttacker0After = int256(currency0.balanceOf(attacker));
// //         int256 balanceAttacker1After = int256(currency1.balanceOf(attacker));
// //         vm.stopPrank();

// //         uint256 currency0Total2;
// //         uint256 currency1Total2;

// //         (filled,,, currency0Total2, currency1Total2, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertTrue(filled, "order should be filled");
// //         assertEq(liquidityTotal, 1e15, "liquidityTotal should be liquidity");
// //         assertApproxEqAbs(currency0Total2, currency0Total, 1, "attacker should not withdraw fees accrued");
// //         assertApproxEqAbs(
// //             currency1Total2,
// //             currency1Total / 2 + uint256(uint128(initialFeesExpected1)) / 2,
// //             1,
// //             "attacker should not withdraw fees accrued"
// //         );

// //         // cancel the order is the same as remove liquidity from the pool in the range (0, tickSpacing)
// //         vm.startPrank(user);

// //         int256 balanceUser0BeforeWithdraw = int256(currency0.balanceOf(user));
// //         int256 balanceUser1BeforeWithdraw = int256(currency1.balanceOf(user));
// //         hook.withdraw(OrderIdLibrary.OrderId.wrap(1), user);
// //         int256 balanceUser0AfterWithdraw = int256(currency0.balanceOf(user));
// //         int256 balanceUser1AfterWithdraw = int256(currency1.balanceOf(user));
// //         vm.stopPrank();

// //         (,,, currency0Total, currency1Total, liquidityTotal) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertApproxEqAbs(liquidityTotal, 0, 1, "liquidityTotal should be 0");
// //         assertApproxEqAbs(currency0Total, 0, 1, "currency0Total should be 0");
// //         assertApproxEqAbs(currency1Total, 0, 1, "currency1Total should be 0");

// //         assertApproxEqAbs(
// //             balanceAttacker0After - balanceAttacker0Before,
// //             balanceUser0AfterWithdraw - balanceUser0BeforeWithdraw - int256(uint256(uint128(initialFeesExpected0))),
// //             1,
// //             "fees should go to the user who withdraws the order"
// //         );
// //         assertApproxEqAbs(
// //             balanceAttacker1After - balanceAttacker1Before,
// //             balanceUser1AfterWithdraw - balanceUser1BeforeWithdraw - int256(uint256(uint128(initialFeesExpected1))),
// //             1,
// //             "fees should go to the user who withdraws the order"
// //         );
// //     }

// //     function test_swapAcrossRange() public {
// //         int24 tickLower = 0;
// //         bool zeroForOne = true;
// //         uint128 liquidity = 1000000;

// //         hook.placeOrder(key, tickLower, zeroForOne, liquidity);

// //         int24 currentTick = getCurrentTick(key.toId());

// //         assertEq(currentTick, tickLower, "Initial tick is wrong");

// //         swapRouter.swap(
// //             key,
// //             SwapParams({
// //                 zeroForOne: true,
// //                 amountSpecified: -1e17,
// //                 sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower - 10 * key.tickSpacing)
// //             }),
// //             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
// //             ZERO_BYTES
// //         );

// //         currentTick = getCurrentTick(key.toId());
// //         assertEq(currentTick, tickLower - 10 * key.tickSpacing, "Tick after swap 1 is wrong");

// //         swapRouter.swap(
// //             key,
// //             SwapParams({
// //                 zeroForOne: false,
// //                 amountSpecified: -1e17,
// //                 sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower + key.tickSpacing / 2)
// //             }),
// //             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
// //             ZERO_BYTES
// //         );

// //         currentTick = getCurrentTick(key.toId());
// //         assertEq(currentTick, tickLower + key.tickSpacing / 2, "Tick after swap 2 is wrong");

// //         (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         swapRouter.swap(
// //             key,
// //             SwapParams({
// //                 zeroForOne: true,
// //                 amountSpecified: -1e17,
// //                 sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLower - key.tickSpacing / 2)
// //             }),
// //             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
// //             ZERO_BYTES
// //         );

// //         (filled,,, currency0Total, currency1Total,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(1));

// //         assertFalse(filled, "order should be filled");
// //         assertEq(currency0Total, 0, "wrong amount of currency0");
// //         assertEq(currency1Total, 0, "wrong amount of currency1"); // 3013, 2 wei of dust

// //         bytes32 positionId = Position.calculatePositionKey(address(hook), tickLower, tickLower + key.tickSpacing, 0);
// //         assertEq(manager.getPositionLiquidity(key.toId(), positionId), liquidity);

// //         vm.expectRevert(LimitOrderHook.NotFilled.selector);
// //         hook.withdraw(OrderIdLibrary.OrderId.wrap(1), address(this));
// //     }
// }
