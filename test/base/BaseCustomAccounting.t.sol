// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {BaseCustomAccountingMock} from "test/mocks/BaseCustomAccountingMock.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BaseCustomAccounting} from "src/base/BaseCustomAccounting.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

contract BaseCustomAccountingTest is Test, Deployers {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

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

    BaseCustomAccountingMock hook;

    uint256 constant MAX_DEADLINE = 12329839823;
    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();

        hook = BaseCustomAccountingMock(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                )
            )
        );
        deployCodeTo(
            "test/mocks/BaseCustomAccountingMock.sol:BaseCustomAccountingMock", abi.encode(manager), address(hook)
        );

        deployMintAndApprove2Currencies();
        (key, id) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        ERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 99 ether, 99 ether, address(this), block.timestamp + 1000
            )
        );

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_beforeInitialize_poolKey_succeeds() public view {
        (Currency _currency0, Currency _currency1, uint24 _fee, int24 _tickSpacing, IHooks _hooks) = hook.poolKey();

        assertEq(Currency.unwrap(_currency0), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(_currency1), Currency.unwrap(currency1));
        assertEq(_fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(_tickSpacing, 60);
        assertEq(address(_hooks), address(hook));
    }

    function test_addLiquidity_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        BaseCustomAccounting.AddLiquidityParams memory addLiquidityParams =
            BaseCustomAccounting.AddLiquidityParams(10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE);

        hook.addLiquidity(addLiquidityParams);

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal);

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        // Include liquidity provided in set up
        assertEq(liquidityTokenBal, 110 ether + 5);
    }

    function test_addLiquidity_fuzz_succeeds(uint112 amount) public {
        hook.addLiquidity(BaseCustomAccounting.AddLiquidityParams(amount, amount, 0, 0, address(this), MAX_DEADLINE));

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal);
    }

    function test_addLiquidity_swapThenAdd_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE)
        );

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal);
        assertEq(liquidityTokenBal, 110 ether + 5);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        // Set rate to 100% to return all
        hook.setRate(10000);

        vm.expectEmit(true, true, true, true, address(manager));
        emit Swap(
            id, address(swapRouter), -1 ether, 990990990990990990, 78514395284406100317958588947, 110 ether + 5, -182, 0
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, settings, ZERO_BYTES);

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether - 1 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 9009009009009009010);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(5 ether, 5 ether, 4 ether, 4 ether, address(this), MAX_DEADLINE)
        );

        liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal);
        assertEq(liquidityTokenBal, 114954954954954954960);
    }

    function test_addLiquidity_expired_revert() public {
        vm.expectRevert(BaseCustomAccounting.ExpiredPastDeadline.selector);
        hook.addLiquidity(BaseCustomAccounting.AddLiquidityParams(0, 0, 0, 0, address(this), block.timestamp - 1));
    }

    function test_addLiquidity_tooMuchSlippage_reverts() public {
        vm.expectRevert(BaseCustomAccounting.TooMuchSlippage.selector);
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                10 ether, 10 ether, 100000 ether, 100000 ether, address(this), MAX_DEADLINE
            )
        );
    }

    function test_swap_twoSwaps_succeeds() public {
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_2});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, settings, ZERO_BYTES);
        swapRouter.swap(key, params, settings, ZERO_BYTES);
    }

    function test_removeLiquidity_initialRemove_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.approve(address(hook), type(uint256).max);

        BaseCustomAccounting.RemoveLiquidityParams memory removeLiquidityParams =
            BaseCustomAccounting.RemoveLiquidityParams(1 ether, MAX_DEADLINE);

        hook.removeLiquidity(removeLiquidityParams);

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal);
        assertEq(hook.balanceOf(address(this)), 99 ether + 5);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 + 1 ether - 1);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 + 1 ether - 1);
    }

    function test_removeLiquidity_fuzz_succeeds(uint256 amount) public {
        if (amount > hook.balanceOf(address(this))) {
            vm.expectRevert();
            hook.removeLiquidity(BaseCustomAccounting.RemoveLiquidityParams(amount, MAX_DEADLINE));
        } else {
            uint256 prevLiquidityTokenBal = hook.balanceOf(address(this));
            hook.removeLiquidity(BaseCustomAccounting.RemoveLiquidityParams(amount, MAX_DEADLINE));

            uint256 liquidityTokenBal = hook.balanceOf(address(this));

            assertEq(prevLiquidityTokenBal - liquidityTokenBal, amount);
            assertEq(manager.getLiquidity(id), liquidityTokenBal);
        }
    }

    function test_removeLiquidity_noLiquidity_reverts() public {
        vm.expectRevert();
        hook.removeLiquidity(BaseCustomAccounting.RemoveLiquidityParams(1000000 ether, MAX_DEADLINE));
    }

    function test_removeLiquidity_partial_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE)
        );

        assertEq(hook.balanceOf(address(this)), 110 ether + 5);
        assertEq(key.currency0.balanceOfSelf(), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOfSelf(), prevBalance1 - 10 ether);

        hook.removeLiquidity(BaseCustomAccounting.RemoveLiquidityParams(5 ether, MAX_DEADLINE));

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal);
        assertEq(liquidityTokenBal, 105 ether + 5);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 5 ether - 1);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 5 ether - 1);
    }

    function test_removeLiquidity_diffRatios_succeeds() public {
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(10 ether, 10 ether, 9 ether, 9 ether, address(this), MAX_DEADLINE)
        );

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);
        assertEq(hook.balanceOf(address(this)), 110 ether + 5);

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(5 ether, 2.5 ether, 2 ether, 2 ether, address(this), MAX_DEADLINE)
        );

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 12.5 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 12.5 ether);
        assertEq(hook.balanceOf(address(this)), 112.5 ether + 5);

        hook.removeLiquidity(BaseCustomAccounting.RemoveLiquidityParams(5 ether, MAX_DEADLINE));

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        assertEq(manager.getLiquidity(id), liquidityTokenBal);
        assertEq(liquidityTokenBal, 107.5 ether + 5);
        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 7.5 ether - 1);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 7.5 ether - 1);
    }

    function test_removeLiquidity_allFuzz_succeeds(uint112 amount) public {
        hook.addLiquidity(BaseCustomAccounting.AddLiquidityParams(amount, amount, 0, 0, address(this), MAX_DEADLINE));

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        hook.removeLiquidity(BaseCustomAccounting.RemoveLiquidityParams(liquidityTokenBal, MAX_DEADLINE));

        assertEq(manager.getLiquidity(id), 0);
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
                100 ether, 100 ether, 99 ether, 99 ether, address(this), MAX_DEADLINE
            )
        );

        // address(2) adds liquidity
        vm.prank(address(2));
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams(
                100 ether, 100 ether, 99 ether, 99 ether, address(this), MAX_DEADLINE
            )
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100 ether, sqrtPriceLimitX96: SQRT_PRICE_1_4});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Test contract removes liquidity, succeeds
        hook.removeLiquidity(BaseCustomAccounting.RemoveLiquidityParams(hook.balanceOf(address(this)), MAX_DEADLINE));

        // PoolManager does not have any liquidity left over
        assertEq(manager.getLiquidity(id), 0);
    }

    function test_removeLiquidity_swapRemoveAllFuzz_succeeds(uint112 amount) public {
        vm.assume(amount > 4);

        hook.addLiquidity(BaseCustomAccounting.AddLiquidityParams(amount, amount, 0, 0, address(this), MAX_DEADLINE));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: (FullMath.mulDiv(amount, 1, 4)).toInt256(),
            sqrtPriceLimitX96: SQRT_PRICE_1_4
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 liquidityTokenBal = hook.balanceOf(address(this));

        hook.removeLiquidity(BaseCustomAccounting.RemoveLiquidityParams(liquidityTokenBal, MAX_DEADLINE));

        assertEq(manager.getLiquidity(id), 0);
    }
}
