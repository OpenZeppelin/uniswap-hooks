// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Internal imports
import {HookTest} from "../utils/HookTest.sol";
import {BaseAsyncSwapMock} from "../../src/mocks/base/BaseAsyncSwapMock.sol";

contract BaseAsyncSwapTest is HookTest {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint16;

    BaseAsyncSwapMock hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        hook = BaseAsyncSwapMock(address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)));
        deployCodeTo(
            "src/mocks/base/BaseAsyncSwapMock.sol:BaseAsyncSwapMock", abi.encode(address(manager)), address(hook)
        );

        deployMintAndApprove2Currencies();
        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_swap_exactInput_succeeds() public {
        SwapParams memory swapParams =
            SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), 0, 0, 79228162514264337593543950336, 1e18, 0, 0);

        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(balance0Before - balance0After, 100);
        assertEq(balance1Before, balance1After);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 100);
    }

    function test_swap_exactOutput_succeeds() public {
        SwapParams memory swapParams =
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -101, 100, 79228162514264329670727698909, 1e18, -1, 0);

        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        // async swaps are not applied to exact-output swaps
        assertEq(balance0Before - balance0After, 101);
        assertEq(balance1After - balance1Before, 100);
    }

    function test_swap_exactInput_notZeroForOne_succeeds() public {
        SwapParams memory swapParams =
            SwapParams({zeroForOne: false, amountSpecified: -100, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), 0, 0, 79228162514264337593543950336, 1e18, 0, 0);

        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(balance1Before - balance1After, 100);
        assertEq(balance0Before, balance0After);
    }

    function test_swap_exactOutput_notZeroForOne_succeeds() public {
        SwapParams memory swapParams =
            SwapParams({zeroForOne: false, amountSpecified: 100, sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), 100, -101, 79228162514264345516360201763, 1e18, 0, 0);

        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(balance1Before - balance1After, 101);
        assertEq(balance0After - balance0Before, 100);
    }

    /// @dev Per `IHookEvents.HookSwap` NatSpec: amount0/amount1 are positive for input, negative for output.
    /// `BaseAsyncSwap` only acts on exact-input swaps (the input side is taken and the swap is netted to 0,
    /// so the output side is reported as 0). Exact-output swaps are delegated to the `PoolManager`, so no
    /// `HookSwap` is emitted. Exercises all 4 (zeroForOne x exactInput) combinations in a single test.
    function test_hookSwap_event_correctSigns() public {
        int128 amount = 100;

        for (uint256 i = 0; i < 4; i++) {
            bool zeroForOne = i < 2;
            bool exactInput = i % 2 == 0;
            string memory tag =
                string.concat("[zeroForOne=", zeroForOne ? "T" : "F", ", exactInput=", exactInput ? "T" : "F", "] ");

            SwapParams memory params = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactInput ? -int256(int128(amount)) : int256(int128(amount)),
                sqrtPriceLimitX96: zeroForOne ? SQRT_PRICE_1_2 : MAX_PRICE_LIMIT
            });

            vm.recordLogs();
            swapRouter.swap(
                key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
            );
            (bytes memory data, bool found) = findLogData(vm.getRecordedLogs(), address(hook), HookSwap.selector);

            if (!exactInput) {
                assertFalse(found, string.concat(tag, "exact-output must not emit HookSwap"));
                continue;
            }

            assertTrue(found, string.concat(tag, "HookSwap should be emitted"));
            (int128 amount0, int128 amount1,,) = abi.decode(data, (int128, int128, uint128, uint128));

            if (zeroForOne) {
                // currency0 is input -> positive; currency1 is output -> 0 (async netting)
                assertEq(amount0, amount, string.concat(tag, "amount0 (input) should equal +specifiedAmount"));
                assertEq(amount1, int128(0), string.concat(tag, "amount1 (output) is netted to 0"));
            } else {
                // currency1 is input -> positive; currency0 is output -> 0 (async netting)
                assertEq(amount0, int128(0), string.concat(tag, "amount0 (output) is netted to 0"));
                assertEq(amount1, amount, string.concat(tag, "amount1 (input) should equal +specifiedAmount"));
            }
        }
    }

    function test_swap_fuzz_succeeds(bool zeroForOne, int120 amountSpecified) public {
        vm.assume(amountSpecified != 0);

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        if (amountSpecified < 0 && zeroForOne) {
            assertEq(delta.amount0(), amountSpecified);
            assertEq(delta.amount1(), 0);
        } else if (amountSpecified < 0 && !zeroForOne) {
            assertEq(delta.amount0(), 0);
            assertEq(delta.amount1(), amountSpecified);
        } else if (amountSpecified > 0 && zeroForOne) {
            assertTrue(delta.amount0() < 0);
            assertTrue(delta.amount1() > 0);
        } else {
            assertTrue(delta.amount0() > 0);
            assertTrue(delta.amount1() < 0);
        }
    }
}
