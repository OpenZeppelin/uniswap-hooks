// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// Internal imports
import {BaseHookFeeMock} from "../../src/mocks/fee/BaseHookFeeMock.sol";
import {HookTest} from "../utils/HookTest.sol";

contract BaseHookFeeTest is HookTest {
    using SafeCast for *;

    uint256 public constant MAX_HOOK_FEE = 1e6;
    BaseHookFeeMock hook;
    PoolKey noHookKey;

    // 0.1% fee in hundredths of a bip (pips)
    uint24 public hookFee = 1000;

    address public withdrawer;

    PoolSwapTest.TestSettings public testSettings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        withdrawer = makeAddr("withdrawer");

        hook = BaseHookFeeMock(address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)));
        deployCodeTo(
            "src/mocks/fee/BaseHookFeeMock.sol:BaseHookFeeMock",
            abi.encode(address(manager), hookFee, withdrawer),
            address(hook)
        );

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        (noHookKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_swap_zeroForOne_exactInput() public {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18, // exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exactInput && zeroForOne == true => currency0 is specified, currency1 is unspecified
        uint256 hookCurrency0Claims = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookCurrency1Claims = manager.balanceOf(address(hook), currency1.toId());

        uint256 deltaUnspecifiedNoHook = deltaNoHook.amount1().toUint256();
        uint256 expectedFee = Math.mulDiv(deltaUnspecifiedNoHook, hookFee, MAX_HOOK_FEE, Math.Rounding.Ceil);

        assertEq(hookCurrency0Claims, 0);
        assertEq(hookCurrency1Claims, expectedFee);
    }

    function test_swap_zeroForOne_exactOutput() public {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18, // exact output
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exactOutput && zeroForOne == true => currency1 is specified, currency0 is unspecified
        uint256 hookCurrency0Claims = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookCurrency1Claims = manager.balanceOf(address(hook), currency1.toId());

        uint256 deltaUnspecifiedNoHook = (-deltaNoHook.amount0()).toUint256();
        uint256 expectedFee = Math.mulDiv(deltaUnspecifiedNoHook, hookFee, MAX_HOOK_FEE, Math.Rounding.Ceil);

        assertEq(hookCurrency0Claims, expectedFee);
        assertEq(hookCurrency1Claims, 0);
    }

    function test_swap_notZeroForOne_exactInput() public {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e18, // exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exactInput && zeroForOne == false => currency1 is specified, currency0 is unspecified
        uint256 hookCurrency0Claims = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookCurrency1Claims = manager.balanceOf(address(hook), currency1.toId());

        uint256 deltaUnspecifiedNoHook = (deltaNoHook.amount0()).toUint256();
        uint256 expectedFee = Math.mulDiv(deltaUnspecifiedNoHook, hookFee, MAX_HOOK_FEE, Math.Rounding.Ceil);

        assertEq(hookCurrency0Claims, expectedFee);
        assertEq(hookCurrency1Claims, 0);
    }

    function test_swap_notZeroForOne_exactOutput() public {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: false,
            amountSpecified: 1e18, // exact output
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exactOutput && zeroForOne == false => currency0 is specified, currency1 is unspecified
        uint256 hookCurrency0Claims = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookCurrency1Claims = manager.balanceOf(address(hook), currency1.toId());

        uint256 deltaUnspecifiedNoHook = (-deltaNoHook.amount1()).toUint256();
        uint256 expectedFee = Math.mulDiv(deltaUnspecifiedNoHook, hookFee, MAX_HOOK_FEE, Math.Rounding.Ceil);

        assertEq(hookCurrency0Claims, 0);
        assertEq(hookCurrency1Claims, expectedFee);
    }

    function test_swap_feeBelowOneUnit_roundsUp() public {
        SwapParams memory swapParams =
            SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");
        uint256 unspecified = deltaNoHook.amount1().toUint256();
        assertLt(unspecified * hookFee, MAX_HOOK_FEE);

        swapRouter.swap(key, swapParams, testSettings, "");

        assertEq(manager.balanceOf(address(hook), currency1.toId()), 1);
    }

    /// @dev `BaseHookFee` emits `HookFee` on the unspecified currency of the swap (the side the hook charges
    /// the fee on). The fee currency depends on (zeroForOne, exactInput): the unspecified side is `currency1`
    /// when `zeroForOne == exactInput`, and `currency0` otherwise. Exercises all 4 combinations in a single test.
    function test_hookFee_event_emittedOnUnspecifiedCurrency() public {
        int128 amount = 1e10;

        for (uint256 i = 0; i < 4; i++) {
            bool zeroForOne = i < 2;
            bool exactInput = i % 2 == 0;
            string memory tag =
                string.concat("[zeroForOne=", zeroForOne ? "T" : "F", ", exactInput=", exactInput ? "T" : "F", "] ");

            SwapParams memory params = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactInput ? -int256(int128(amount)) : int256(int128(amount)),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            });

            vm.recordLogs();
            swapRouter.swap(key, params, testSettings, "");
            (bytes memory data, bool found) = findLogData(vm.getRecordedLogs(), address(hook), HookFee.selector);
            assertTrue(found, string.concat(tag, "HookFee not emitted"));
            (uint128 fee0, uint128 fee1) = abi.decode(data, (uint128, uint128));

            // Unspecified currency is currency1 when (exactInput == zeroForOne), else currency0.
            bool feeOnCurrency1 = exactInput == zeroForOne;
            if (feeOnCurrency1) {
                assertEq(fee0, 0, string.concat(tag, "fee0 should be zero"));
                assertGt(fee1, 0, string.concat(tag, "fee1 should be non-zero"));
            } else {
                assertGt(fee0, 0, string.concat(tag, "fee0 should be non-zero"));
                assertEq(fee1, 0, string.concat(tag, "fee1 should be zero"));
            }
        }
    }

    function test_withdrawFees() public {
        SwapParams memory swapParams1 = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18, // exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        SwapParams memory swapParams2 = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e16, // exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams1, testSettings, "");
        swapRouter.swap(key, swapParams2, testSettings, "");

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = currency0;
        currencies[1] = currency1;

        uint256 balance0Before = currency0.balanceOf(withdrawer);
        uint256 balance1Before = currency1.balanceOf(withdrawer);

        uint256 hookCurrency0ClaimsBefore = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookCurrency1ClaimsBefore = manager.balanceOf(address(hook), currency1.toId());

        vm.prank(withdrawer);
        hook.handleHookFees(currencies);

        uint256 balance0After = currency0.balanceOf(withdrawer);
        uint256 balance1After = currency1.balanceOf(withdrawer);

        assertEq(balance0After, balance0Before + hookCurrency0ClaimsBefore);
        assertEq(balance1After, balance1Before + hookCurrency1ClaimsBefore);

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "currency0 claims != 0");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "currency1 claims != 0");
    }
}
