// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {LiquidityPenaltyHook} from "src/general/LiquidityPenaltyHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract LiquidityPenaltyHookTest is Test, Deployers {
    LiquidityPenaltyHook hook;
    PoolKey noHookKey;
    uint24 fee = 1000; // 0.1%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LiquidityPenaltyHook(
            address(
                uint160(
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
                )
            )
        );
        deployCodeTo("src/general/LiquidityPenaltyHook.sol:LiquidityPenaltyHook", abi.encode(manager, 1), address(hook));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
        (noHookKey,) = initPool(currency0, currency1, IHooks(address(0)), fee, SQRT_PRICE_1_1);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    // Helper functions

    function calculateExpectedFees(
        IPoolManager manager,
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (int128, int128) {
        bytes32 positionKey = Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            StateLibrary.getPositionInfo(manager, poolId, positionKey);

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            StateLibrary.getFeeGrowthInside(manager, poolId, tickLower, tickUpper);

        uint256 feesExpected0 =
            FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
        uint256 feesExpected1 =
            FullMath.mulDiv(feeGrowthInside1X128 - feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);

        return (int128(int256(feesExpected0)), int128(int256(feesExpected1)));
    }

    function modifyPoolLiquidity(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity,
        bytes32 salt
    ) internal returns (BalanceDelta) {
        ModifyLiquidityParams memory modifyLiquidityParams =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: salt});
        return modifyLiquidityRouter.modifyLiquidity(poolKey, modifyLiquidityParams, "");
    }

    // Tests

    function test_deploy_LowOffset_reverts() public {
        vm.expectRevert();
        deployCodeTo("src/general/LiquidityPenaltyHook.sol:LiquidityPenaltyHook", abi.encode(manager, 0), address(hook));
    }

    function test_addLiquidity_noSwap() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // remove liquidity
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook));
    }

    function test_addLiquidity_Swap_JIT_SingleLP() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        uint128 liquidityHookKey = StateLibrary.getLiquidity(manager, key.toId());
        uint128 liquidityNoHookKey = StateLibrary.getLiquidity(manager, noHookKey.toId());

        // when removing all of the liquidity, the liquidity provider (even in a jit attack) should get the fees
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -int128(liquidityHookKey), 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -int128(liquidityNoHookKey), 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook));
    }

    function test_addLiquidity_Swap_JIT() public {
        bool zeroForOne = true;

        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        (int128 feesExpected0, int128 feesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        // remove liquidity
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook) - feesExpected0);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook) - feesExpected1);

        vm.roll(block.number + 1);
        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        uint128 liquidityHookKey = StateLibrary.getLiquidity(manager, key.toId());
        uint128 liquidityNoHookKey = StateLibrary.getLiquidity(manager, noHookKey.toId());

        assertEq(liquidityHookKey, liquidityNoHookKey);

        BalanceDelta deltaHookNextBlock = modifyPoolLiquidity(key, -600, 600, -int128(liquidityHookKey), 0);
        BalanceDelta deltaNoHookNextBlock = modifyPoolLiquidity(noHookKey, -600, 600, -int128(liquidityNoHookKey), 0);

        assertEq(
            BalanceDeltaLibrary.amount0(deltaHookNextBlock),
            BalanceDeltaLibrary.amount0(deltaNoHookNextBlock) + feesExpected0
        );
        assertEq(
            BalanceDeltaLibrary.amount1(deltaHookNextBlock),
            BalanceDeltaLibrary.amount1(deltaNoHookNextBlock) + feesExpected1
        );
    }

    function test_addLiquidity_MultipleSwaps_JIT() public {
        // add liquidity
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams1 = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        SwapParams memory swapParams2 = SwapParams({
            zeroForOne: false,
            amountSpecified: 1e15, //exact output
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        SwapParams memory swapParams3 = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        SwapParams memory swapParams4 = SwapParams({
            zeroForOne: true,
            amountSpecified: 1e15, //exact output
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams1, testSettings, "");
        swapRouter.swap(key, swapParams2, testSettings, "");
        swapRouter.swap(key, swapParams3, testSettings, "");
        swapRouter.swap(key, swapParams4, testSettings, "");

        swapRouter.swap(noHookKey, swapParams1, testSettings, "");
        swapRouter.swap(noHookKey, swapParams2, testSettings, "");
        swapRouter.swap(noHookKey, swapParams3, testSettings, "");
        swapRouter.swap(noHookKey, swapParams4, testSettings, "");

        (int128 feesExpected0, int128 feesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook) - feesExpected0);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook) - feesExpected1);
    }

    function test_addLiquidity_RemoveNextBlock() public {
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        swapRouter.swap(key, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        vm.roll(block.number + 1);
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook));
    }

    function test_donateToPool_JIT() public {
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        donateRouter.donate(key, 100000, 100000, "");
        donateRouter.donate(noHookKey, 100000, 100000, "");

        (int128 feesExpected0, int128 feesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook) - feesExpected0);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook) - feesExpected1);
    }

    function test_donateToPool_RemoveNextBlock() public {
        modifyPoolLiquidity(key, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        donateRouter.donate(key, 100000, 100000, "");
        donateRouter.donate(noHookKey, 100000, 100000, "");

        vm.roll(block.number + 1);
        BalanceDelta deltaHook = modifyPoolLiquidity(key, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook));
    }

    function testFuzz_BlockNumberOffset_JIT(uint24 offset, uint24 removeBlockQuantity) public {
        vm.assume(offset > 1);
        vm.assume(removeBlockQuantity < offset);

        LiquidityPenaltyHook newHook = LiquidityPenaltyHook(
            address(
                uint160(
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
                ) + 2 ** 96
            ) // 2**96 is an offset to avoid collision with the hook address already in the test
        );

        deployCodeTo(
            "src/general/LiquidityPenaltyHook.sol:LiquidityPenaltyHook", abi.encode(manager, offset), address(newHook)
        );

        (PoolKey memory poolKey,) = initPool(currency0, currency1, IHooks(address(newHook)), fee, SQRT_PRICE_1_1);

        // add liquidity
        modifyPoolLiquidity(poolKey, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        (int128 feesExpected0, int128 feesExpected1) =
            calculateExpectedFees(manager, noHookKey.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0));

        int128 feeDonation0 =
            SafeCast.toInt128(FullMath.mulDiv(SafeCast.toUint128(feesExpected0), offset - removeBlockQuantity, offset));
        int128 feeDonation1 =
            SafeCast.toInt128(FullMath.mulDiv(SafeCast.toUint128(feesExpected1), offset - removeBlockQuantity, offset));

        // remove liquidity
        vm.roll(block.number + removeBlockQuantity);
        BalanceDelta deltaHook = modifyPoolLiquidity(poolKey, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook) - feeDonation0);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook) - feeDonation1);
    }

    function testFuzz_BlockNumberOffset_RemoveAfterSwap(uint24 offset, uint24 removeBlockQuantity) public {
        vm.assume(offset > 1);
        vm.assume(removeBlockQuantity > offset);

        LiquidityPenaltyHook newHook = LiquidityPenaltyHook(
            address(
                uint160(
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
                ) + 2 ** 96
            ) // 2**96 is an offset to avoid collision with the hook address already in the test
        );

        deployCodeTo(
            "src/general/LiquidityPenaltyHook.sol:LiquidityPenaltyHook", abi.encode(manager, offset), address(newHook)
        );

        (PoolKey memory poolKey,) = initPool(currency0, currency1, IHooks(address(newHook)), fee, SQRT_PRICE_1_1);

        // add liquidity
        modifyPoolLiquidity(poolKey, -600, 600, 1e18, 0);
        modifyPoolLiquidity(noHookKey, -600, 600, 1e18, 0);

        // swap
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKey, swapParams, testSettings, "");
        swapRouter.swap(noHookKey, swapParams, testSettings, "");

        vm.roll(block.number + removeBlockQuantity);
        BalanceDelta deltaHook = modifyPoolLiquidity(poolKey, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook = modifyPoolLiquidity(noHookKey, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook), BalanceDeltaLibrary.amount0(deltaNoHook));
        assertEq(BalanceDeltaLibrary.amount1(deltaHook), BalanceDeltaLibrary.amount1(deltaNoHook));
    }

    function test_addLiquidity_Swap_MultipleKeys_JIT() public {
        (PoolKey memory poolKeyWithHook1,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_2);
        (PoolKey memory poolKeyWithHook2,) = initPool(currency0, currency1, IHooks(address(hook)), 5000, SQRT_PRICE_2_1);

        (PoolKey memory poolKeyWithoutHook1,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_2);
        (PoolKey memory poolKeyWithoutHook2,) = initPool(currency0, currency1, IHooks(address(0)), 5000, SQRT_PRICE_2_1);

        //add liquidity to both pools
        modifyPoolLiquidity(poolKeyWithHook1, -600, 600, 1e18, 0);
        modifyPoolLiquidity(poolKeyWithHook2, -600, 600, 1e18, 0);

        modifyPoolLiquidity(poolKeyWithoutHook1, -600, 600, 1e18, 0);
        modifyPoolLiquidity(poolKeyWithoutHook2, -600, 600, 1e18, 0);

        //swap in both pools
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15, //exact input
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKeyWithHook1, swapParams, testSettings, "");
        swapRouter.swap(poolKeyWithHook2, swapParams, testSettings, "");

        swapRouter.swap(poolKeyWithoutHook1, swapParams, testSettings, "");
        swapRouter.swap(poolKeyWithoutHook2, swapParams, testSettings, "");

        (int128 feesExpected0Key1, int128 feesExpected1Key1) = calculateExpectedFees(
            manager, poolKeyWithoutHook1.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0)
        );
        (int128 feesExpected0Key2, int128 feesExpected1Key2) = calculateExpectedFees(
            manager, poolKeyWithoutHook2.toId(), address(modifyLiquidityRouter), -600, 600, bytes32(0)
        );

        //remove liquidity from both pools
        BalanceDelta deltaHook1 = modifyPoolLiquidity(poolKeyWithHook1, -600, 600, -1e17, 0);
        BalanceDelta deltaHook2 = modifyPoolLiquidity(poolKeyWithHook2, -600, 600, -1e17, 0);

        BalanceDelta deltaNoHook1 = modifyPoolLiquidity(poolKeyWithoutHook1, -600, 600, -1e17, 0);
        BalanceDelta deltaNoHook2 = modifyPoolLiquidity(poolKeyWithoutHook2, -600, 600, -1e17, 0);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook1), BalanceDeltaLibrary.amount0(deltaNoHook1) - feesExpected0Key1);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook1), BalanceDeltaLibrary.amount1(deltaNoHook1) - feesExpected1Key1);

        assertEq(BalanceDeltaLibrary.amount0(deltaHook2), BalanceDeltaLibrary.amount0(deltaNoHook2) - feesExpected0Key2);
        assertEq(BalanceDeltaLibrary.amount1(deltaHook2), BalanceDeltaLibrary.amount1(deltaNoHook2) - feesExpected1Key2);
    }
}
