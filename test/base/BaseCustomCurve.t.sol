// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BaseCustomAccounting} from "src/base/BaseCustomAccounting.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// Internal imports
import {BaseCustomCurveMock} from "../../src/mocks/base/BaseCustomCurveMock.sol";
import {HookTest} from "../utils/HookTest.sol";

contract BaseCustomCurveTest is HookTest {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    BaseCustomCurveMock hook;

    uint256 constant MAX_DEADLINE = 12329839823;

    // Minimum and maximum ticks for a spacing of 60
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();

        hook = BaseCustomCurveMock(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    )
                ))
        );
        deployCodeTo(
            "src/mocks/base/BaseCustomCurveMock.sol:BaseCustomCurveMock", abi.encode(address(manager)), address(hook)
        );

        deployMintAndApprove2Currencies();
        (key, id) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_beforeInitialize_poolKey_succeeds() public view {
        PoolKey memory key = hook.poolKey();

        assertEq(Currency.unwrap(key.currency0), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(key.currency1), Currency.unwrap(currency1));
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(key.tickSpacing, 60);
        assertEq(address(key.hooks), address(hook));
    }

    function test_initialize_already_reverts() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    function test_addLiquidity_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        BaseCustomAccounting.AddLiquidityParams memory addLiquidityParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );

        hook.addLiquidity(addLiquidityParams);

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        assertEq(liquidityTokenBal, 20 ether);
    }

    function test_addLiquidity_native_succeeds() public {
        BaseCustomCurveMock nativeHook = BaseCustomCurveMock(payable(0x1000000000000000000000000000000000002A88));
        deployCodeTo(
            "src/mocks/base/BaseCustomCurveMock.sol:BaseCustomCurveMock",
            abi.encode(address(manager)),
            address(nativeHook)
        );
        (key, id) = initPool(
            CurrencyLibrary.ADDRESS_ZERO,
            currency1,
            IHooks(address(nativeHook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        ERC20(Currency.unwrap(currency1)).approve(address(nativeHook), type(uint256).max);
        vm.label(address(0), "native");

        deal(address(this), 10 ether);

        uint256 prevBalance0 = address(this).balance;
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        BaseCustomAccounting.AddLiquidityParams memory addLiquidityParams = BaseCustomAccounting.AddLiquidityParams(
            10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );

        nativeHook.addLiquidity{value: 10 ether}(addLiquidityParams);

        uint256 liquidityTokenBal = nativeHook.balanceOf(address(this));

        assertEq(address(this).balance, prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        assertEq(liquidityTokenBal, 20 ether);
    }

    function test_addLiquidity_fuzz_succeeds(uint112 amount) public {
        vm.assume(amount > 0);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(amount, amount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );

        uint256 liquidityTokenBal = hook.balanceOf(address(this));
        assertEq(liquidityTokenBal, uint256(amount) * 2);
    }

    function test_addLiquidity_swapThenAdd_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(liquidityTokenBal, 20 ether);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(id, address(swapRouter), 0, 0, 79228162514264337593543950336, 0, 0, 0);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, settings, ZERO_BYTES);

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 9 ether);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                5 ether, 5 ether, 4 ether, 4 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(liquidityTokenBal, 30 ether);
    }

    function test_addLiquidity_expired_revert() public {
        vm.expectRevert(BaseCustomAccounting.ExpiredPastDeadline.selector);
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(0, 0, 0, 0, block.timestamp - 1, MIN_TICK, MAX_TICK, bytes32(0))
        );
    }

    function test_addLiquidity_tooMuchSlippage_reverts() public {
        vm.expectRevert(BaseCustomAccounting.TooMuchSlippage.selector);
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 100000 ether, 100000 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
    }

    function test_removeLiquidity_tooMuchSlippage_reverts() public {
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        vm.expectRevert(BaseCustomAccounting.TooMuchSlippage.selector);
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                10 ether, 6 ether, 6 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                10 ether, 4 ether, 4 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
    }

    function test_swap_twoSwaps_succeeds() public {
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                2 ether, 2 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, settings, ZERO_BYTES);
        swapRouter.swap(key, params, settings, ZERO_BYTES);
    }

    function test_removeLiquidity_initialRemove_succeeds() public {
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 99 ether, 99 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.approve(address(hook), type(uint256).max);

        BaseCustomAccounting.RemoveLiquidityParams memory removeLiquidityParams =
            BaseCustomAccounting.RemoveLiquidityParams(1 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0));

        hook.removeLiquidity(removeLiquidityParams);

        uint256 liquidityTokenBal = hook.balanceOf(address(this));
        assertEq(liquidityTokenBal, 199 ether);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 + 0.5 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 + 0.5 ether);
    }

    function test_removeLiquidity_fuzz_succeeds(uint256 amount) public {
        vm.assume(amount > 0);

        if (amount > hook.balanceOf(address(this))) {
            vm.expectRevert();
            hook.removeLiquidity(
                BaseCustomAccounting.RemoveLiquidityParams(amount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
            );
        } else {
            uint256 prevLiquidityTokenBal = hook.balanceOf(address(this));
            hook.removeLiquidity(
                BaseCustomAccounting.RemoveLiquidityParams(amount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
            );

            uint256 liquidityTokenBal = hook.balanceOf(address(this));

            assertEq(prevLiquidityTokenBal - liquidityTokenBal, amount);
            assertEq(manager.getLiquidity(id), liquidityTokenBal);
        }
    }

    function test_removeLiquidity_noLiquidity_reverts() public {
        vm.expectRevert();
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                1000000 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
    }

    function test_removeLiquidity_partial_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        assertEq(hook.balanceOf(address(this)), 20 ether);
        assertEq(key.currency0.balanceOfSelf(), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOfSelf(), prevBalance1 - 10 ether);

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(5 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );

        uint256 liquidityTokenBal = hook.balanceOf(address(this));
        assertEq(liquidityTokenBal, 15 ether);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 7.5 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 7.5 ether);
    }

    function test_removeLiquidity_diffRatios_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);
        assertEq(hook.balanceOf(address(this)), 20 ether);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                5 ether, 2.5 ether, 2 ether, 2 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 15 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 12.5 ether);
        assertEq(hook.balanceOf(address(this)), 27.5 ether);

        // Reserves are 15 and 12.5 against a supply of 27.5, so 5.5 shares redeem 3 and 2.5
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(5.5 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );

        uint256 liquidityTokenBal = hook.balanceOf(address(this));
        assertEq(liquidityTokenBal, 22 ether);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 12 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);
    }

    function test_removeLiquidity_allFuzz_succeeds(uint112 amount) public {
        vm.assume(amount > 0);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(amount, amount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                liquidityTokenBal, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        assertEq(manager.getLiquidity(id), 0);
    }

    function test_removeLiquidity_native_succeeds() public {
        BaseCustomCurveMock nativeHook = BaseCustomCurveMock(payable(0x1000000000000000000000000000000000002A88));
        deployCodeTo(
            "src/mocks/base/BaseCustomCurveMock.sol:BaseCustomCurveMock",
            abi.encode(address(manager)),
            address(nativeHook)
        );
        (key, id) = initPool(
            CurrencyLibrary.ADDRESS_ZERO,
            currency1,
            IHooks(address(nativeHook)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        ERC20(Currency.unwrap(currency1)).approve(address(nativeHook), type(uint256).max);
        vm.label(address(0), "native");

        deal(address(this), 10 ether);

        uint256 prevBalance0 = address(this).balance;
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        nativeHook.addLiquidity{value: 10 ether}(
            BaseCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        uint256 liquidityTokenBal = nativeHook.balanceOf(address(this));

        nativeHook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                liquidityTokenBal, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        assertEq(manager.getLiquidity(id), 0);

        // Redeeming every share returns the whole deposit
        assertEq(address(this).balance, prevBalance0);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1);
    }

    function test_removeLiquidity_multiple_succeeds() public {
        // Mint tokens for dummy addresses
        deal(Currency.unwrap(currency0), address(1), 2 ** 128);
        deal(Currency.unwrap(currency1), address(1), 2 ** 128);
        deal(Currency.unwrap(currency0), address(2), 2 ** 128);
        deal(Currency.unwrap(currency1), address(2), 2 ** 128);

        // Approve the hook
        vm.prank(address(1));
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        vm.prank(address(1));
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.prank(address(2));
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        vm.prank(address(2));
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // address(1) adds liquidity
        vm.prank(address(1));
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 99 ether, 99 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        // address(2) adds liquidity
        vm.prank(address(2));
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 99 ether, 99 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: SQRT_PRICE_1_4});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Test contract removes liquidity, succeeds
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                hook.balanceOf(address(this)), 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        // PoolManager does not have any liquidity left over
        assertEq(manager.getLiquidity(id), 0);
    }

    function test_removeLiquidity_swapRemoveAllFuzz_succeeds(uint112 amount) public {
        vm.assume(amount > 4);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(amount, amount, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: (FullMath.mulDiv(amount, 1, 4)).toInt256(),
            sqrtPriceLimitX96: SQRT_PRICE_1_4
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                liquidityTokenBal, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        assertEq(manager.getLiquidity(id), 0);
    }

    function test_removeLiquidity_notInitialized_reverts() public {
        BaseCustomCurveMock uninitializedHook = BaseCustomCurveMock(payable(0x1000000000000000000000000000000000002A88));
        deployCodeTo(
            "src/mocks/base/BaseCustomCurveMock.sol:BaseCustomCurveMock",
            abi.encode(address(manager)),
            address(uninitializedHook)
        );

        vm.expectRevert(BaseCustomAccounting.PoolNotInitialized.selector);
        uninitializedHook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(1 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );
    }

    function test_addLiquidity_notInitialized_reverts() public {
        BaseCustomCurveMock uninitializedHook = BaseCustomCurveMock(payable(0x1000000000000000000000000000000000002A88));
        deployCodeTo(
            "src/mocks/base/BaseCustomCurveMock.sol:BaseCustomCurveMock",
            abi.encode(address(manager)),
            address(uninitializedHook)
        );

        vm.expectRevert(BaseCustomAccounting.PoolNotInitialized.selector);
        uninitializedHook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                1 ether, 1 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
    }

    function test_swap_addThenRemove_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(0, 1 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(liquidityTokenBal, 1 ether);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 1 ether);

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(id, address(swapRouter), 0, 0, 79228162514264337593543950336, 0, 0, 0);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, settings, ZERO_BYTES);

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 0.5 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 0.5 ether);

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                hook.balanceOf(address(this)), 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        liquidityTokenBal = hook.balanceOf(address(this));

        // The swap moved the reserves but not their total, so redeeming every share returns the whole deposit
        assertEq(liquidityTokenBal, 0);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1);
    }

    /// @dev A swap can move the whole reserve into one currency. Redemptions are quoted against the reserves, so
    /// they stay feasible and pay out only what the hook holds.
    function test_removeLiquidity_depletedReserve_succeeds() public {
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        assertEq(hook.balanceOf(address(this)), 200 ether);

        // Swap out every unit of currency1 held by the hook
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 200 ether);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(2 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );

        assertEq(hook.balanceOf(address(this)), 198 ether);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 + 2 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1);
    }

    /// @dev Shares are backed by the reserves, so the last redemption empties the hook whatever the swaps did to
    /// the composition of those reserves.
    function test_removeLiquidity_lastExit_strandsNothing() public {
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                hook.balanceOf(address(this)), 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        assertEq(hook.totalSupply(), 0);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    /// @dev Minting and redemption are inverses, so a deposit of any ratio survives a round trip untouched.
    function test_removeLiquidity_roundTripFuzz_succeeds(uint112 amount0, uint112 amount1) public {
        vm.assume(uint256(amount0) + uint256(amount1) > 0);

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                amount0, amount1, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                hook.balanceOf(address(this)), 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1);
        assertEq(hook.totalSupply(), 0);
    }

    /// @dev Equal deposits earn equal shares, and a swap between the two redemptions moves the reserve composition
    /// without moving its total, so both providers withdraw the value they put in.
    function test_removeLiquidity_twoProviders_noDilution() public {
        deal(Currency.unwrap(currency0), address(1), 2 ** 100);
        deal(Currency.unwrap(currency1), address(1), 2 ** 100);
        vm.startPrank(address(1));
        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        BaseCustomAccounting.AddLiquidityParams memory addParams = BaseCustomAccounting.AddLiquidityParams(
            100 ether, 100 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
        );

        hook.addLiquidity(addParams);
        vm.prank(address(1));
        hook.addLiquidity(addParams);

        assertEq(hook.balanceOf(address(this)), hook.balanceOf(address(1)));

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -50 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(
                hook.balanceOf(address(this)), 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        assertEq(
            (key.currency0.balanceOf(address(this)) - prevBalance0)
                + (key.currency1.balanceOf(address(this)) - prevBalance1),
            200 ether
        );

        uint256 prevOther0 = key.currency0.balanceOf(address(1));
        uint256 prevOther1 = key.currency1.balanceOf(address(1));
        uint256 otherShares = hook.balanceOf(address(1));
        vm.prank(address(1));
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(otherShares, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );
        assertEq(
            (key.currency0.balanceOf(address(1)) - prevOther0) + (key.currency1.balanceOf(address(1)) - prevOther1),
            200 ether
        );
    }

    /// @dev Per `IHookEvents.HookSwap` NatSpec: amount0/amount1 are positive for input, negative for output.
    /// The mock is a constant-sum 1:1 curve, so the absolute values are equal on both sides. Exercises all 4
    /// (zeroForOne x exactInput) combinations in a single test.
    function test_hookSwap_event_correctSigns() public {
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );

        int128 amount = 0.1 ether;

        for (uint256 i = 0; i < 4; i++) {
            bool zeroForOne = i < 2;
            bool exactInput = i % 2 == 0;
            string memory tag =
                string.concat("[zeroForOne=", zeroForOne ? "T" : "F", ", exactInput=", exactInput ? "T" : "F", "] ");

            SwapParams memory params = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactInput ? -int256(int128(amount)) : int256(int128(amount)),
                sqrtPriceLimitX96: zeroForOne ? SQRT_PRICE_1_2 : SQRT_PRICE_2_1
            });

            vm.recordLogs();
            swapRouter.swap(
                key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
            );

            (bytes memory data, bool found) = findLogData(vm.getRecordedLogs(), address(hook), HookSwap.selector);
            assertTrue(found, string.concat(tag, "HookSwap not emitted"));
            (int128 amount0, int128 amount1,,) = abi.decode(data, (int128, int128, uint128, uint128));

            // Constant-sum 1:1 curve: |amount0| == |amount1| == amount.
            // Input side is always currency`zeroForOne ? 0 : 1`.
            (int128 expected0, int128 expected1) = zeroForOne ? (amount, -amount) : (-amount, amount);
            assertEq(amount0, expected0, string.concat(tag, "amount0 sign/magnitude mismatch"));
            assertEq(amount1, expected1, string.concat(tag, "amount1 sign/magnitude mismatch"));
        }
    }

    /// @dev Per the `BaseCustomCurve._modifyLiquidity` flow, the emitted `HookModifyLiquidity` amounts
    /// are caller-perspective deltas: negative when adding (caller pays the pool) and positive when removing
    /// (caller receives from the pool). Exercises both add and remove for both currencies in a single test.
    function test_hookModifyLiquidity_event_correctSigns() public {
        // Add liquidity -> amounts must be negative (caller pays).
        vm.recordLogs();
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 9 ether, 9 ether, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0)
            )
        );
        (bytes memory addData, bool addFound) =
            findLogData(vm.getRecordedLogs(), address(hook), HookModifyLiquidity.selector);
        assertTrue(addFound, "HookModifyLiquidity not emitted on add");
        (int128 addAmount0, int128 addAmount1) = abi.decode(addData, (int128, int128));
        assertEq(addAmount0, -int128(10 ether), "add: amount0 should equal -addedAmount0");
        assertEq(addAmount1, -int128(10 ether), "add: amount1 should equal -addedAmount1");

        // Remove liquidity -> amounts must be positive (caller receives).
        hook.approve(address(hook), type(uint256).max);
        vm.recordLogs();
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams(2 ether, 0, 0, MAX_DEADLINE, MIN_TICK, MAX_TICK, bytes32(0))
        );
        (bytes memory remData, bool remFound) =
            findLogData(vm.getRecordedLogs(), address(hook), HookModifyLiquidity.selector);
        assertTrue(remFound, "HookModifyLiquidity not emitted on remove");
        (int128 remAmount0, int128 remAmount1) = abi.decode(remData, (int128, int128));
        // Mock returns liquidity/2 for each currency, so removing 2 ether -> 1 ether per side.
        assertEq(remAmount0, int128(1 ether), "remove: amount0 should equal +removedAmount0");
        assertEq(remAmount1, int128(1 ether), "remove: amount1 should equal +removedAmount1");
    }
}
