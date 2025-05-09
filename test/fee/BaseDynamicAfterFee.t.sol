// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {BaseDynamicAfterFee} from "src/fee/BaseDynamicAfterFee.sol";
import {BaseDynamicAfterFeeMock} from "test/mocks/BaseDynamicAfterFeeMock.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {Deploy} from "v4-periphery/test/shared/Deploy.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

contract BaseDynamicAfterFeeTest is Test, Deployers {
    using SafeCast for uint256;

    BaseDynamicAfterFeeMock dynamicFeesHook;
    IV4Quoter quoter;

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

        dynamicFeesHook = BaseDynamicAfterFeeMock(
            payable(
                address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG))
            )
        );
        deployCodeTo(
            "test/mocks/BaseDynamicAfterFeeMock.sol:BaseDynamicAfterFeeMock",
            abi.encode(manager),
            address(dynamicFeesHook)
        );

        deployMintAndApprove2Currencies();
        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(dynamicFeesHook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");

        quoter = IV4Quoter(address(Deploy.v4Quoter(address(manager), "")));
    }

    function test_swap_100PercentLPFeeExactInput_succeeds() public {
        assertEq(dynamicFeesHook.getTargetOutput(), 0);

        dynamicFeesHook.setTargetOutput(0, true);
        uint256 currentOutput = dynamicFeesHook.getTargetOutput();
        assertEq(currentOutput, 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        uint256 balanceBefore = currency1.balanceOf(address(this));

        swapRouter.swap(key, SWAP_PARAMS, testSettings, ZERO_BYTES);

        assertEq(dynamicFeesHook.getTargetOutput(), 0);
        assertEq(currency1.balanceOf(address(dynamicFeesHook)), 99);
        assertEq(currency1.balanceOf(address(this)), balanceBefore);
    }

    function test_swap_100PercentLPFeeExactInputNative_succeeds() public {
        BaseDynamicAfterFeeMock nativeHook =
            BaseDynamicAfterFeeMock(payable(0x10000000000000000000000000000000000000C4));
        deployCodeTo(
            "test/mocks/BaseDynamicAfterFeeMock.sol:BaseDynamicAfterFeeMock", abi.encode(manager), address(nativeHook)
        );
        (key,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO,
            currency1,
            IHooks(address(nativeHook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1,
            1 ether
        );

        ERC20(Currency.unwrap(currency1)).approve(address(nativeHook), type(uint256).max);
        vm.label(address(0), "native");

        deal(address(this), 10 ether);

        assertEq(nativeHook.getTargetOutput(), 0);

        nativeHook.setTargetOutput(0, true);
        uint256 currentOutput = nativeHook.getTargetOutput();
        assertEq(currentOutput, 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        uint256 balanceBefore = currency1.balanceOf(address(this));

        swapRouter.swap{value: 100}(key, SWAP_PARAMS, testSettings, ZERO_BYTES);

        assertEq(nativeHook.getTargetOutput(), 0);
        assertEq(currency1.balanceOf(address(nativeHook)), 99);
        assertEq(currency1.balanceOf(address(this)), balanceBefore);
    }

    function test_swap_50PercentLPFeeExactInput_succeeds() public {
        assertEq(dynamicFeesHook.getTargetOutput(), 0);

        dynamicFeesHook.setTargetOutput(49, true);
        uint256 currentOutput = dynamicFeesHook.getTargetOutput();
        assertEq(currentOutput, 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);

        uint256 balanceBefore = currency1.balanceOf(address(this));

        swapRouter.swap(key, SWAP_PARAMS, testSettings, ZERO_BYTES);

        assertEq(dynamicFeesHook.getTargetOutput(), 0);
        assertEq(currency1.balanceOf(address(dynamicFeesHook)), 50);
        assertEq(currency1.balanceOf(address(this)), balanceBefore + 49);
    }

    function test_swap_skipped_succeeds() public {
        assertEq(dynamicFeesHook.getTargetOutput(), 0);

        dynamicFeesHook.setTargetOutput(999, false);
        uint256 currentOutput = dynamicFeesHook.getTargetOutput();
        assertEq(currentOutput, 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -100, 99, 79228162514264329670727698910, 1e18, -1, 0);
        swapRouter.swap(key, SWAP_PARAMS, testSettings, ZERO_BYTES);

        assertEq(dynamicFeesHook.getTargetOutput(), 0);
    }

    function test_swap_50PercentLPFeeExactOutput_succeeds() public {
        assertEq(dynamicFeesHook.getTargetOutput(), 0);

        dynamicFeesHook.setTargetOutput(50, true);
        uint256 currentOutput = dynamicFeesHook.getTargetOutput();
        assertEq(currentOutput, 0);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(key.toId(), address(swapRouter), -101, 100, 79228162514264329670727698909, 1e18, -1, 0);

        // No fee is applied because this is an exact-output swap
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        assertEq(dynamicFeesHook.getTargetOutput(), 0);
    }

    function test_swap_deltaExceeds_succeeds() public {
        assertEq(dynamicFeesHook.getTargetOutput(), 0);

        dynamicFeesHook.setTargetOutput(101, true);
        uint256 currentOutput = dynamicFeesHook.getTargetOutput();
        assertEq(currentOutput, 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(dynamicFeesHook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(BaseDynamicAfterFee.TargetOutputExceeds.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(key, SWAP_PARAMS, testSettings, ZERO_BYTES);

        assertEq(dynamicFeesHook.getTargetOutput(), 0);
    }

    function test_swap_fuzz_succeeds(bool zeroForOne, uint24 lpFee, uint128 amountSpecified) public {
        assertEq(dynamicFeesHook.getTargetOutput(), 0);

        lpFee = uint24(bound(lpFee, 0, 1e6));
        amountSpecified = uint128(bound(amountSpecified, 1, 6017734268818166));
        (uint256 amountUnspecified,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: amountSpecified,
                hookData: ZERO_BYTES
            })
        );
        uint256 deltaFee = (amountUnspecified * lpFee) / 1e6;
        uint256 targetAmount = amountUnspecified - deltaFee;
        dynamicFeesHook.setTargetOutput(targetAmount, true);

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int128(amountSpecified),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        if (zeroForOne) {
            assertEq(delta.amount0(), -int128(amountSpecified));
            assertEq(delta.amount1(), targetAmount.toInt128());
        } else {
            assertEq(delta.amount0(), targetAmount.toInt128());
            assertEq(delta.amount1(), -int128(amountSpecified));
        }
    }
}
