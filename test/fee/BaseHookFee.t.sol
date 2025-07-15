// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BaseHookFeeMock} from "test/mocks/BaseHookFeeMock.sol";

contract BaseHookFeeTest is Test, Deployers {
    BaseHookFeeMock hook;
    PoolKey noHookKey;

    uint256 public hookFee = 1000; // 0.1%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = BaseHookFeeMock(address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)));
        deployCodeTo("test/mocks/BaseHookFeeMock.sol:BaseHookFeeMock", abi.encode(manager, hookFee), address(hook));

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        (noHookKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_swap_zeroForOne_fixed_input() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18, // exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        BalanceDelta deltaHook = swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exact input && zeroForOne == true => currency1 is the unspecified currency
        uint256 hookCurrency0Balance = currency0.balanceOf(address(hook));
        uint256 hookCurrency1Balance = currency1.balanceOf(address(hook));

        assertEq(hookCurrency0Balance, 0);
        uint256 deltaUnspecifiedNoHook = uint256(uint128(deltaNoHook.amount1()));
        uint256 expectedFee = FullMath.mulDiv(deltaUnspecifiedNoHook, hookFee, 1e6);
        assertEq(hookCurrency1Balance, expectedFee);
    }

    function test_swap_zeroForOne_fixed_output() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18, // exact output
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        BalanceDelta deltaHook = swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exact output && zeroForOne == true => currency0 is the unspecified currency
        uint256 hookCurrency0Balance = currency0.balanceOf(address(hook));
        uint256 hookCurrency1Balance = currency1.balanceOf(address(hook));

        assertEq(hookCurrency1Balance, 0);
        uint256 deltaUnspecifiedNoHook = uint256(uint128(-deltaNoHook.amount0()));
        uint256 expectedFee = FullMath.mulDiv(deltaUnspecifiedNoHook, hookFee, 1e6);
        assertEq(hookCurrency0Balance, expectedFee);
    }

    function test_swap_notZeroForOne_fixed_input() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -1e18, // exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        BalanceDelta deltaHook = swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exact input && zeroForOne == false => currency0 is the specified currency
        uint256 hookCurrency0Balance = currency0.balanceOf(address(hook));
        uint256 hookCurrency1Balance = currency1.balanceOf(address(hook));

        assertEq(hookCurrency1Balance, 0);
        uint256 deltaSpecifiedNoHook = uint256(uint128(deltaNoHook.amount0()));
        uint256 expectedFee = FullMath.mulDiv(deltaSpecifiedNoHook, hookFee, 1e6);
        assertEq(hookCurrency0Balance, expectedFee);
    }

    function test_swap_notZeroForOne_fixed_output() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 1e18, // exact output
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams, testSettings, "");
        BalanceDelta deltaNoHook = swapRouter.swap(noHookKey, swapParams, testSettings, "");

        // exact output && zeroForOne == false => currency1 is the specified currency
        uint256 hookCurrency0Balance = currency0.balanceOf(address(hook));
        uint256 hookCurrency1Balance = currency1.balanceOf(address(hook));

        assertEq(hookCurrency0Balance, 0);
        uint256 deltaSpecifiedNoHook = uint256(uint128(-deltaNoHook.amount1()));
        uint256 expectedFee = FullMath.mulDiv(deltaSpecifiedNoHook, hookFee, 1e6);
        assertEq(hookCurrency1Balance, expectedFee);
    }

    function test_withdrawFees() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams1 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18, // exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        IPoolManager.SwapParams memory swapParams2 = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -1e16, // exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams1, testSettings, "");
        swapRouter.swap(key, swapParams2, testSettings, "");

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = currency0;
        currencies[1] = currency1;

        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));

        uint256 hookCurrency0BalanceBefore = currency0.balanceOf(address(hook));
        uint256 hookCurrency1BalanceBefore = currency1.balanceOf(address(hook));

        hook.withdrawFees(currencies);

        uint256 balance0After = currency0.balanceOf(address(this));
        uint256 balance1After = currency1.balanceOf(address(this));

        assertEq(balance0After, balance0Before + hookCurrency0BalanceBefore);
        assertEq(balance1After, balance1Before + hookCurrency1BalanceBefore);

        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }
}
