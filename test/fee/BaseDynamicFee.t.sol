// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {BaseDynamicFeeMock} from "test/mocks/BaseDynamicFeeMock.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

contract BaseDynamicFeeTest is Test, Deployers {
    BaseDynamicFeeMock hook;
    PoolKey noHookKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = BaseDynamicFeeMock(address(uint160(Hooks.AFTER_INITIALIZE_FLAG)));
        deployCodeTo("test/mocks/BaseDynamicFeeMock.sol:BaseDynamicFeeMock", abi.encode(manager), address(hook));

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        (noHookKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 100, SQRT_PRICE_1_1);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    /// @notice Unit test for a single swap zero for one exact in.
    function test_swap_zeroForOne_exactIn() public {
        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountToSwap),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 - amountToSwap, "amount 0");
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 + 949098356561266, "amount 1");
    }

    /// @notice Unit test for a single swap zero for one exact out.
    function test_swap_zeroForOne_exactOut() public {
        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amountToSwap),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 - 1053685264211582, "amount 0");
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 + amountToSwap, "amount 1");
    }

    /// @notice Unit test for a single swap one for zero exact in.
    function test_swap_oneForZero_exactIn() public {
        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(amountToSwap),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 + 949098356561266, "amount 0");
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 - amountToSwap, "amount 1");
    }

    /// @notice Unit test for a single swap one for zero exact out.
    function test_swap_oneForZero_exactOut() public {
        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        uint256 amountToSwap = 1e15;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: int256(amountToSwap),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertEq(currency0.balanceOf(address(this)), balanceBefore0 + amountToSwap, "amount 0");
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 - 1053685264211582, "amount 1");
    }
}
