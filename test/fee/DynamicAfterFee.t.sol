// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {DynamicAfterFeeMock} from "test/mocks/DynamicAfterFeeMock.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract DynamicAfterFeeTest is Test, Deployers {
    DynamicAfterFeeMock dynamicFeesHook;

    event Swap(
        PoolId indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    event Donate(PoolId indexed id, address indexed sender, uint256 amount0, uint256 amount1);

    function setUp() public {
        deployFreshManagerAndRouters();

        dynamicFeesHook =
            DynamicAfterFeeMock(address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)));
        deployCodeTo(
            "test/mocks/DynamicAfterFeeMock.sol:DynamicAfterFeeMock", abi.encode(manager), address(dynamicFeesHook)
        );

        deployMintAndApprove2Currencies();
        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(dynamicFeesHook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_swap_100PercentLPFeeExactInput_succeeds() public {
        assertEq(BalanceDelta.unwrap(dynamicFeesHook.getTargetDelta(key.toId())), 0);

        dynamicFeesHook.setTargetDelta(key.toId(), toBalanceDelta(-100, 0));
        BalanceDelta currentDelta = dynamicFeesHook.getTargetDelta(key.toId());
        assertEq(currentDelta.amount0(), -100);
        assertEq(currentDelta.amount1(), 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);
        vm.expectEmit(true, true, true, true, address(manager));
        emit Donate(key.toId(), address(dynamicFeesHook), 0, 99);

        swapRouter.swap(key, SWAP_PARAMS, testSettings, ZERO_BYTES);

        assertEq(BalanceDelta.unwrap(dynamicFeesHook.getTargetDelta(key.toId())), 0);
    }

    function test_swap_50PercentLPFeeExactInput_succeeds() public {
        assertEq(BalanceDelta.unwrap(dynamicFeesHook.getTargetDelta(key.toId())), 0);

        dynamicFeesHook.setTargetDelta(key.toId(), toBalanceDelta(-100, 49));
        BalanceDelta currentDelta = dynamicFeesHook.getTargetDelta(key.toId());
        assertEq(currentDelta.amount0(), -100);
        assertEq(currentDelta.amount1(), 49);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);
        vm.expectEmit(true, true, true, true, address(manager));
        emit Donate(key.toId(), address(dynamicFeesHook), 0, 50);

        swapRouter.swap(key, SWAP_PARAMS, testSettings, ZERO_BYTES);

        assertEq(BalanceDelta.unwrap(dynamicFeesHook.getTargetDelta(key.toId())), 0);
    }

    function test_swap_50PercentLPFeeExactOutput_succeeds() public {
        assertEq(BalanceDelta.unwrap(dynamicFeesHook.getTargetDelta(key.toId())), 0);

        dynamicFeesHook.setTargetDelta(key.toId(), toBalanceDelta(-101, 50));
        BalanceDelta currentDelta = dynamicFeesHook.getTargetDelta(key.toId());
        assertEq(currentDelta.amount0(), -101);
        assertEq(currentDelta.amount1(), 50);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -101, 100, 79228162514264329670727698909, 1e18, -1, 0);

        // No fee is applied because this is an exact-output swap
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        currentDelta = dynamicFeesHook.getTargetDelta(key.toId());
        assertEq(currentDelta.amount0(), -101);
        assertEq(currentDelta.amount1(), 50);
    }

    function test_swap_deltaExceeds_succeeds() public {
        assertEq(BalanceDelta.unwrap(dynamicFeesHook.getTargetDelta(key.toId())), 0);

        dynamicFeesHook.setTargetDelta(key.toId(), toBalanceDelta(-100, 101));
        BalanceDelta currentDelta = dynamicFeesHook.getTargetDelta(key.toId());
        assertEq(currentDelta.amount0(), -100);
        assertEq(currentDelta.amount1(), 101);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        // Target delta has no effect given that target amount1 exceeds the swap delta
        swapRouter.swap(key, SWAP_PARAMS, testSettings, ZERO_BYTES);

        assertEq(BalanceDelta.unwrap(dynamicFeesHook.getTargetDelta(key.toId())), 0);
    }

    function test_swap_fuzz_succeeds(bool zeroForOne, uint24 lpFee, uint128 amountSpecified) public {
        assertEq(BalanceDelta.unwrap(dynamicFeesHook.getTargetDelta(key.toId())), 0);

        zeroForOne = false;
        lpFee = uint24(bound(lpFee, 10000, 1000000));
        amountSpecified = uint128(bound(amountSpecified, 1, 6017734268818166));

        uint256 deltaFee = (uint256(amountSpecified) * lpFee) / 1000000;
        int128 targetAmount1 = deltaFee > 0 ? int128(uint128(amountSpecified - deltaFee)) : int128(0);

        if (zeroForOne) {
            dynamicFeesHook.setTargetDelta(key.toId(), toBalanceDelta(-int128(amountSpecified), targetAmount1));
        } else {
            dynamicFeesHook.setTargetDelta(key.toId(), toBalanceDelta(targetAmount1, -int128(amountSpecified)));
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int128(amountSpecified),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        if (zeroForOne) {
            assertEq(delta.amount0(), -int128(amountSpecified));
            assertEq(delta.amount1(), targetAmount1);
        } else {
            assertEq(delta.amount0(), targetAmount1);
            assertEq(delta.amount1(), -int128(amountSpecified));
        }
    }
}
