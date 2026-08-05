// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {LimitOrderHook, OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {LimitOrderHookMock} from "src/mocks/general/LimitOrderHookMock.sol";
import {HookTest} from "test/utils/HookTest.sol";
import {LimitOrderHookHandler} from "./handlers/LimitOrderHook/LimitOrderHookHandler.sol";

/**
 * @dev INV-05 campaign for `LimitOrderHook`.
 *
 * INV-05: for a filled order, the currency still recorded against the order is at least each
 * remaining owner's checkpoint. Otherwise `total_c - ckpt_c` in `withdraw` underflows and that
 * owner's principal is stranded.
 *
 * See `test/invariant/LimitOrderHook.invariants.md`.
 */
contract LimitOrderHookInvariantsTest is HookTest {
    using StateLibrary for IPoolManager;

    LimitOrderHookMock hook;
    LimitOrderHookHandler handler;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    int24 constant TICK_LOWER = 60;
    bool constant ZERO_FOR_ONE = true;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LimitOrderHookMock(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));
        deployCodeTo(
            "src/mocks/general/LimitOrderHookMock.sol:LimitOrderHookMock", abi.encode(address(manager)), address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;

        int24[] memory ticks = new int24[](4);
        ticks[0] = -2 * key.tickSpacing;
        ticks[1] = -key.tickSpacing;
        ticks[2] = key.tickSpacing;
        ticks[3] = 2 * key.tickSpacing;

        handler = new LimitOrderHookHandler(hook, manager, swapRouter, key, actors, ticks);

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

    /// forge-config: default.invariant.runs = 500
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_INV05_filledOrderTotalsCoverEveryCheckpoint() public view {
        uint232[] memory ids = handler.orderIds();
        address[] memory actors = handler.actors();

        for (uint256 i; i < ids.length; ++i) {
            uint232 id = ids[i];
            (bool filled,,, uint256 total0, uint256 total1,) = hook.getOrderInfo(OrderIdLibrary.OrderId.wrap(id));
            if (!filled) continue;

            for (uint256 a; a < actors.length; ++a) {
                address actor = actors[a];
                if (hook.getOrderLiquidity(OrderIdLibrary.OrderId.wrap(id), actor) == 0) continue;

                (uint256 checkpoint0, uint256 checkpoint1) =
                    hook.getOrderCheckpoint(OrderIdLibrary.OrderId.wrap(id), actor);

                assertGe(total0, checkpoint0, "INV-05: currency0Total below owner checkpoint");
                assertGe(total1, checkpoint1, "INV-05: currency1Total below owner checkpoint");
            }
        }
    }

    /**
     * @dev Coverage proof: a green run means nothing if these counts are zero.
     *
     * Runs once at the end of each sequence, inside the campaign above, so it reports the
     * productivity of a real sequence. A separate `invariant_*` function would run its own
     * independent campaign instead, doubling the cost to print the same thing.
     */
    function afterInvariant() public view {
        console.log("placeOrder     ", handler.calls("placeOrder"));
        console.log("cancelOrder    ", handler.calls("cancelOrder"));
        console.log("withdraw       ", handler.calls("withdraw"));
        console.log("swapTo         ", handler.calls("swapTo"));
        console.log("swapRoundTrip  ", handler.calls("swapRoundTrip"));
        console.log("orders created ", handler.orderIdCount());
    }

    /**
     * @dev Minimization of the fuzzer's INV-05 counterexample.
     *
     * Alice opens the order and Bob joins, which realizes the fees accrued while the price passed
     * through the range. Bob's checkpoint is snapshotted before that realization, so it is zero;
     * Alice's second placement inherits the realized total as her checkpoint. Bob withdrawing
     * first then drags `currency0Total` below Alice's checkpoint.
     *
     * Returns the order id and Alice's `currency0` checkpoint.
     */
    function _reachCheckpointSkew() private returns (OrderIdLibrary.OrderId id, uint256 aliceCheckpoint0) {
        vm.prank(alice);
        hook.placeOrder(key, TICK_LOWER, ZERO_FOR_ONE, 1e14);

        id = hook.getOrderId(key, TICK_LOWER, ZERO_FOR_ONE);

        // price enters the order range and leaves downward: fees accrue, no fill
        _swapAsHandler(false, 1e18, TICK_LOWER + key.tickSpacing / 2);
        _swapAsHandler(true, 1e18, 0);

        // bob's placement realizes the accrued fees, but his own checkpoint was already taken
        vm.prank(bob);
        hook.placeOrder(key, TICK_LOWER, ZERO_FOR_ONE, 1e14);

        (,,, aliceCheckpoint0,,) = hook.getOrderInfo(id);
        assertGt(aliceCheckpoint0, 0, "setup: fees should be realized into currency0Total");

        // alice places again and inherits the realized total as her checkpoint
        vm.prank(alice);
        hook.placeOrder(key, TICK_LOWER, ZERO_FOR_ONE, 1e6);

        // price crosses the range: the order fills
        _swapAsHandler(false, 1e20, TICK_LOWER + 2 * key.tickSpacing);

        (bool filled,,,,,) = hook.getOrderInfo(id);
        assertTrue(filled, "setup: order should be filled");
    }

    /// @dev Documents current behavior: INV-05 is violated once the zero-checkpoint owner exits.
    function test_INV05_violationIsReachable() public {
        (OrderIdLibrary.OrderId id, uint256 aliceCheckpoint0) = _reachCheckpointSkew();

        vm.prank(bob);
        hook.withdraw(id, bob);

        (,,, uint256 total0After,,) = hook.getOrderInfo(id);

        assertLt(total0After, aliceCheckpoint0, "INV-05: total0 should have dropped below the checkpoint");
        assertGt(hook.getOrderLiquidity(id, alice), 0, "alice still holds liquidity");
    }

    /// @dev Regression lock for the fix: fails on current code, must pass once withdrawals are
    /// order-independent. Every owner of a filled order can withdraw regardless of who went first.
    function test_INV05_regression_everyOwnerCanWithdraw() public {
        (OrderIdLibrary.OrderId id,) = _reachCheckpointSkew();

        vm.prank(bob);
        hook.withdraw(id, bob);

        vm.prank(alice);
        hook.withdraw(id, alice);

        assertEq(hook.getOrderLiquidity(id, alice), 0, "alice should have withdrawn");
    }

    function _swapAsHandler(bool zeroForOne, uint256 amountIn, int24 tickLimit) private {
        vm.prank(address(handler));
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
}
