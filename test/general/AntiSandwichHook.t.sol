// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BaseDynamicFeeMock} from "../mocks/BaseDynamicFeeMock.sol";
import {AntiSandwichHook} from "src/general/AntiSandwichHook.sol";

contract AntiSandwichHookTest is Test, Deployers {
    AntiSandwichHook hook;
    PoolKey noHookKey;

    BaseDynamicFeeMock dynamicFeesHooks;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = AntiSandwichHook(
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG))
        );
        deployCodeTo("src/general/AntiSandwichHook.sol:AntiSandwichHook", abi.encode(manager), address(hook));

        dynamicFeesHooks = BaseDynamicFeeMock(address(uint160(Hooks.AFTER_INITIALIZE_FLAG)));
        deployCodeTo(
            "test/mocks/BaseDynamicFeeMock.sol:BaseDynamicFeeMock", abi.encode(manager), address(dynamicFeesHooks)
        );

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        (noHookKey,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(dynamicFeesHooks)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    /// @notice Unit test for a single swap, not zero for one.
    function test_swap_single_notZeroForOne() public {
        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 + 999000999000999, "amount 0");
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 - amountToSwap, "amount 1");
    }

    /// @notice Unit test for a single swap, zero for one.
    function test_swap_single_zeroForOne() public {
        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 - amountToSwap, "amount 0");
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 + 999000999000999, "amount 1");
    }

    function test_swap_zeroForOne_exactInput_frontRunExactInput() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        // front run, first transaction
        BalanceDelta deltaAttack1WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack1WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertTrue(deltaAttack1WithKey == deltaAttack1WithoutKey);

        // user swap
        BalanceDelta deltaUserWithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaUserWithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertGt(deltaAttack1WithKey.amount1(), deltaUserWithKey.amount1(), "price didn't increase in the front run");

        assertTrue(deltaUserWithKey == deltaUserWithoutKey);

        // front run, second transaction
        params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(deltaAttack1WithKey.amount1()),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        BalanceDelta deltaAttack2WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack2WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertLe(deltaAttack2WithKey.amount0(), -deltaAttack1WithKey.amount0(), "front runner profit");

        vm.roll(block.number + 1);

        params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        BalanceDelta deltaResetState = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaNextBlock = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        // 997010963116644 is obtained from `test_swap_successfulSandwich`
        assertEq(deltaResetState.amount1(), deltaNextBlock.amount1(), "state did not reset");
    }

    function test_swap_zeroForOne_exactInput_frontRunExactOutput() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        // front run, first transaction
        BalanceDelta deltaAttack1WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack1WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertTrue(deltaAttack1WithKey == deltaAttack1WithoutKey);

        // user swap
        BalanceDelta deltaUserWithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaUserWithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertGt(deltaAttack1WithKey.amount1(), deltaUserWithKey.amount1(), "price didn't increase in the front run");

        assertTrue(deltaUserWithKey == deltaUserWithoutKey);

        // front run, second transaction
        params = SwapParams({
            zeroForOne: false,
            amountSpecified: int256(-deltaAttack1WithKey.amount0()),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        BalanceDelta deltaAttack2WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack2WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertLe(deltaAttack2WithKey.amount0(), -deltaAttack1WithKey.amount0(), "front runner profit");

        vm.roll(block.number + 1);

        params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        BalanceDelta deltaResetState = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaNextBlock = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertEq(deltaResetState.amount1(), deltaNextBlock.amount1(), "state did not reset");
    }

    function test_swap_zeroForOne_exactOutput_frontRunExactInput() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        // front run, first transaction
        BalanceDelta deltaAttack1WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack1WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertTrue(deltaAttack1WithKey == deltaAttack1WithoutKey);

        // user swap
        BalanceDelta deltaUserWithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaUserWithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertLt(-deltaAttack1WithKey.amount0(), -deltaUserWithKey.amount0(), "price didn't decrease in the front run");

        assertTrue(deltaUserWithKey == deltaUserWithoutKey);

        // front run, second transaction
        params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(deltaAttack1WithKey.amount1()),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        BalanceDelta deltaAttack2WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack2WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertLt(deltaAttack2WithKey.amount0(), -deltaAttack1WithKey.amount0(), "front runner profit");

        vm.roll(block.number + 1);

        params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        BalanceDelta deltaResetState = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaNextBlock = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);
        assertEq(deltaResetState.amount0(), deltaNextBlock.amount0(), "state did not reset");
    }

    function test_swap_zeroForOne_exactOutput_frontRunExactOutput() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        // front run, first transaction
        BalanceDelta deltaAttack1WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack1WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertTrue(deltaAttack1WithKey == deltaAttack1WithoutKey);

        // user swap
        BalanceDelta deltaUserWithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaUserWithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertLt(-deltaAttack1WithKey.amount0(), -deltaUserWithKey.amount0(), "price didn't decrease in the front run");

        assertTrue(deltaUserWithKey == deltaUserWithoutKey);

        // front run, second transaction
        params = SwapParams({
            zeroForOne: false,
            amountSpecified: int256(-deltaAttack1WithKey.amount0()),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        BalanceDelta deltaAttack2WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack2WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertLt(deltaAttack2WithKey.amount1(), -deltaAttack1WithKey.amount1(), "front runner profit");

        vm.roll(block.number + 1);

        params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        BalanceDelta deltaResetState = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaNextBlock = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertTrue(deltaResetState == deltaNextBlock, "state did not reset");
    }

    function test_swap_NotZeroForOne_exactInput_frontRun_not_protected() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MAX_PRICE_LIMIT});

        // front run, first transaction
        BalanceDelta deltaAttack1WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack1WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);
        assertTrue(deltaAttack1WithKey == deltaAttack1WithoutKey);

        // user swap
        BalanceDelta deltaUserWithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaUserWithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);
        assertLt(-deltaAttack1WithKey.amount0(), -deltaUserWithKey.amount0(), "price didn't decrease in the front run");

        assertTrue(deltaUserWithKey == deltaUserWithoutKey);

        // front run, second transaction
        params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(deltaAttack1WithKey.amount1()),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        BalanceDelta deltaAttack2WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack2WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertGe(deltaAttack2WithKey.amount0(), -deltaAttack1WithKey.amount0(), "front runner loss");

        vm.roll(block.number + 1);

        params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        BalanceDelta deltaResetState = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaNextBlock = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertTrue(deltaResetState == deltaNextBlock, "state did not reset");
    }

    function test_swap_NotZeroForOne_exactOutput_frontRun_not_protected() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: int256(amountToSwap), sqrtPriceLimitX96: MAX_PRICE_LIMIT});

        // front run, first transaction
        BalanceDelta deltaAttack1WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack1WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertTrue(deltaAttack1WithKey == deltaAttack1WithoutKey);

        BalanceDelta deltaUserWithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaUserWithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertGt(deltaAttack1WithKey.amount1(), deltaUserWithKey.amount1(), "price didn't increase in the front run");

        assertTrue(deltaUserWithKey == deltaUserWithoutKey);

        // front run, second transaction
        params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(deltaAttack1WithKey.amount0()),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        BalanceDelta deltaAttack2WithKey = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaAttack2WithoutKey = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertGe(deltaAttack2WithKey.amount1(), -deltaAttack1WithKey.amount1(), "front runner loss");

        vm.roll(block.number + 1);

        params =
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MAX_PRICE_LIMIT});

        BalanceDelta deltaResetState = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        BalanceDelta deltaNextBlock = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertTrue(deltaResetState == deltaNextBlock, "state did not reset");
    }

    /// @notice Unit test for a failed sandwich attack using the hook.
    function test_swap_failedSandwich() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        // front run, first transaction
        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // user swap
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // front run, second transaction
        params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(delta.amount1()),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        BalanceDelta deltaEnd = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertLe(deltaEnd.amount0(), -delta.amount0(), "front runner profit");
    }

    /// @notice Unit test for a successful sandwich attack without using the hook.
    function test_swap_successfulSandwich() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        // front run, first transaction
        BalanceDelta delta = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        // user swap
        swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        // front run, second transaction
        params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(delta.amount1()),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        BalanceDelta deltaEnd = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertGe(deltaEnd.amount0(), -delta.amount0(), "front runner loss");

        params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);
    }

    /// @notice Unit test for a successful sandwich attack without using the hook, in the opposite direction.
    function test_swap_successfulSandwich_opposite() public {
        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        // front run, first transaction
        BalanceDelta delta = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        // user swap
        swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        // front run, second transaction
        params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(delta.amount0()),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        BalanceDelta deltaEnd = swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);

        assertGe(deltaEnd.amount1(), -delta.amount1(), "front runner loss");

        params =
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountToSwap), sqrtPriceLimitX96: MAX_PRICE_LIMIT});

        swapRouter.swap(noHookKey, params, testSettings, ZERO_BYTES);
    }
}
