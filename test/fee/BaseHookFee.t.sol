// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
// Internal imports
import {BaseHookFeeMock} from "src/mocks/BaseHookFeeMock.sol";
import {HookTest} from "test/utils/HookTest.sol";

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
        deployCodeTo("src/mocks/BaseHookFeeMock.sol:BaseHookFeeMock", abi.encode(hookFee, withdrawer), address(hook));

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

        BalanceDelta deltaHook = swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exactInput && zeroForOne == true => currency0 is specified, currency1 is unspecified
        uint256 hookCurrency0Claims = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookCurrency1Claims = manager.balanceOf(address(hook), currency1.toId());

        uint256 deltaUnspecifiedNoHook = deltaNoHook.amount1().toUint256();
        uint256 expectedFee = FullMath.mulDiv(deltaUnspecifiedNoHook, hookFee, MAX_HOOK_FEE);

        assertEq(hookCurrency0Claims, 0);
        assertEq(hookCurrency1Claims, expectedFee);
    }

    function test_swap_zeroForOne_exactOutput() public {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18, // exact output
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        BalanceDelta deltaHook = swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exactInput && zeroForOne == false => currency1 is specified, currency0 is unspecified
        uint256 hookCurrency0Claims = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookCurrency1Claims = manager.balanceOf(address(hook), currency1.toId());

        uint256 deltaUnspecifiedNoHook = (-deltaNoHook.amount0()).toUint256();
        uint256 expectedFee = FullMath.mulDiv(deltaUnspecifiedNoHook, hookFee, MAX_HOOK_FEE);

        assertEq(hookCurrency0Claims, expectedFee);
        assertEq(hookCurrency1Claims, 0);
    }

    function test_swap_notZeroForOne_exactInput() public {
        SwapParams memory swapParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e18, // exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        BalanceDelta deltaHook = swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exactInput && zeroForOne == false => currency1 is specified, currency0 is unspecified
        uint256 hookCurrency0Claims = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookCurrency1Claims = manager.balanceOf(address(hook), currency1.toId());

        uint256 deltaUnspecifiedNoHook = (deltaNoHook.amount0()).toUint256();
        uint256 expectedFee = FullMath.mulDiv(deltaUnspecifiedNoHook, hookFee, MAX_HOOK_FEE);

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

        // exactInput && zeroForOne == true => currency0 is specified, currency1 is unspecified
        uint256 hookCurrency0Claims = manager.balanceOf(address(hook), currency0.toId());
        uint256 hookCurrency1Claims = manager.balanceOf(address(hook), currency1.toId());

        uint256 deltaSpecifiedNoHook = (-deltaNoHook.amount1()).toUint256();
        uint256 expectedFee = FullMath.mulDiv(deltaSpecifiedNoHook, hookFee, MAX_HOOK_FEE);

        assertEq(hookCurrency0Claims, 0);
        assertEq(hookCurrency1Claims, expectedFee);
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
