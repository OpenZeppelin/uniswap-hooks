// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// External imports
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
// Internal imports
import {
    ReHypothecationERC4626Mock,
    ERC4626YieldSourceMock
} from "../../src/mocks/general/ReHypothecationERC4626Mock.sol";
import {ReHypothecationHook} from "../../src/general/ReHypothecationHook.sol";
import {HookTest} from "../utils/HookTest.sol";
import {BalanceDeltaAssertions} from "../utils/BalanceDeltaAssertions.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

contract ReHypothecationHookERC4626Test is HookTest, BalanceDeltaAssertions {
    using StateLibrary for IPoolManager;
    using SafeCast for *;
    using Math for *;

    ReHypothecationERC4626Mock hook;

    IERC4626 yieldSource0;
    IERC4626 yieldSource1;

    PoolKey noHookKey;

    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");

    uint24 fee = 1000; // 0.1%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        yieldSource0 = IERC4626(new ERC4626YieldSourceMock(IERC20(Currency.unwrap(currency0))));
        yieldSource1 = IERC4626(new ERC4626YieldSourceMock(IERC20(Currency.unwrap(currency1))));

        hook = ReHypothecationERC4626Mock(
            payable(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)))
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
        (noHookKey,) = initPool(currency0, currency1, IHooks(address(0)), fee, SQRT_PRICE_1_1);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");

        _fund([address(manager), address(this), lp1, lp2], [currency0, currency1], 1e30);

        _approveCurrencies(
            [address(this), lp1, lp2],
            [currency0, currency1],
            [address(manager), address(hook), address(swapRouter), address(modifyLiquidityRouter)]
        );
    }

    function _fund(address[4] memory addresses, Currency[2] memory currencies, uint256 amount) internal {
        for (uint256 i = 0; i < addresses.length; i++) {
            for (uint256 j = 0; j < currencies.length; j++) {
                deal(Currency.unwrap(currencies[j]), addresses[i], amount);
            }
        }
    }

    function _approveCurrencies(address[3] memory approvers, Currency[2] memory currencies, address[4] memory spenders)
        internal
    {
        // make `approvers` approve `currencies` to `spenders`
        for (uint256 i = 0; i < approvers.length; i++) {
            vm.startPrank(approvers[i]);
            for (uint256 j = 0; j < currencies.length; j++) {
                for (uint256 k = 0; k < spenders.length; k++) {
                    IERC20(Currency.unwrap(currencies[j])).approve(spenders[k], type(uint256).max);
                }
            }
            vm.stopPrank();
        }
    }

    // -- INITIALIZING -- //

    function test_initialize_already_initialized_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook), // target
                bytes4(BaseHook.beforeInitialize.selector), // selector (beforeInitialize)
                abi.encodeWithSelector(ReHypothecationHook.AlreadyInitialized.selector), // reason
                hex"a9e35b2f" // details
            )
        );
        initPool(currency0, currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
    }

    function test_initialize_native_currency_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(ReHypothecationERC4626Mock.UnsupportedCurrency.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector),
                hex"a9e35b2f"
            )
        );
        initPool(Currency.wrap(address(0)), currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
    }

    // -- ADDING -- //

    function test_add_uninitialized_reverts() public {
        uint160 hookFlags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        ReHypothecationERC4626Mock newHook = ReHypothecationERC4626Mock(
            payable(address(hookFlags + 0x10000000000000000000000000000000)) // generate a different address
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );
        vm.expectRevert(ReHypothecationHook.NotInitialized.selector);
        newHook.addReHypothecatedLiquidity(1e15);
    }

    function test_add_zero_reverts() public {
        vm.expectRevert(ReHypothecationHook.ZeroShares.selector);
        hook.addReHypothecatedLiquidity(0);
    }

    function testFuzz_add_singleLP(uint128 shares) public {
        shares = uint128(bound(shares, 1e12, 1e20));

        uint256 lpAmount0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 lpAmount1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amount0InYieldSource0Before = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource1Before = hook.getAmountInYieldSource(currency1);

        (uint256 previewedAmount0, uint256 previewedAmount1) = hook.previewMint(shares);

        BalanceDelta delta = hook.addReHypothecatedLiquidity(shares);

        assertEq((-delta.amount0()).toUint256(), previewedAmount0, "Delta.amount0() != amount0");
        assertEq((-delta.amount1()).toUint256(), previewedAmount1, "Delta.amount1() != amount1");

        uint256 lpAmount0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 lpAmount1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amount0InYieldSource0After = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource1After = hook.getAmountInYieldSource(currency1);

        assertEq(lpAmount0After, lpAmount0Before - previewedAmount0, "lpAmount0After != lpAmount0Before - amount0");
        assertEq(lpAmount1After, lpAmount1Before - previewedAmount1, "lpAmount1After != lpAmount1Before - amount1");

        assertEq(
            amount0InYieldSource0After,
            amount0InYieldSource0Before + previewedAmount0,
            "Amount0InYieldSource0After != Amount0InYieldSource0Before + Amount0"
        );
        assertEq(
            amount1InYieldSource1After,
            amount1InYieldSource1Before + previewedAmount1,
            "amount1InYieldSource1After != amount1InYieldSource1Before + amount1"
        );

        uint256 obtainedShares = hook.balanceOf(address(this));
        assertEq(obtainedShares, hook.totalSupply(), "obtained shares != total supply");
    }

    function test_add_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        vm.prank(lp1);
        BalanceDelta addDeltalp1 = hook.addReHypothecatedLiquidity(shareslp1);

        vm.prank(lp2);
        BalanceDelta addDeltalp2 = hook.addReHypothecatedLiquidity(shareslp2);

        // both must have paid the same amount of assets
        assertEq(addDeltalp1, addDeltalp2);

        // both must have received the same amount of assets
        assertEq(hook.balanceOf(lp1), hook.balanceOf(lp2));

        // total supply should be the sum of the shares
        assertEq(hook.totalSupply(), shareslp1 + shareslp2);
    }

    function test_add_swap_add_multipleLP() public {
        // both lps want equal amount of shares
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        vm.prank(lp1);
        BalanceDelta addDeltalp1 = hook.addReHypothecatedLiquidity(shareslp1);

        swap(key, true, 1e15, ZERO_BYTES);
        // perform another swap to rebalance the pool
        swap(key, false, 1e15 + 1e10, ZERO_BYTES);

        vm.prank(lp2);
        BalanceDelta addDeltalp2 = hook.addReHypothecatedLiquidity(shareslp2);

        // both must have received the same amount of shares
        assertEq(hook.balanceOf(lp1), hook.balanceOf(lp2));

        // lp2 must have deposited more assets than lp1 to achieve the same shares
        assertGt(-addDeltalp2.amount0(), -addDeltalp1.amount0());
        assertGt(-addDeltalp2.amount1(), -addDeltalp1.amount1());

        // total supply should be the sum of the shares
        assertEq(hook.totalSupply(), shareslp1 + shareslp2);
    }

    function test_add_yieldsGrowth_add_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        vm.prank(lp1);
        BalanceDelta addDeltalp1 = hook.addReHypothecatedLiquidity(shareslp1);

        uint256 amount0InYieldSource = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource = hook.getAmountInYieldSource(currency1);

        // yield1 grows by 10%
        currency0.transfer(address(yieldSource0), amount0InYieldSource * 10 / 100);
        // yield2 grows by 20%
        currency1.transfer(address(yieldSource1), amount1InYieldSource * 20 / 100);

        BalanceDelta addDeltalp2 = hook.addReHypothecatedLiquidity(shareslp2);

        // in order to obtain the same shares as lp1, lp2 must deposit 10% more currency0 and 20% more currency1
        assertApproxEqAbs(-addDeltalp2.amount0(), -addDeltalp1.amount0() * 110 / 100, 1);
        assertApproxEqAbs(-addDeltalp2.amount1(), -addDeltalp1.amount1() * 120 / 100, 1);

        // total supply should be the sum of the shares
        assertEq(hook.totalSupply(), shareslp1 + shareslp2);
    }

    function test_add_yieldsDecay_add_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        vm.prank(lp1);
        BalanceDelta addDeltalp1 = hook.addReHypothecatedLiquidity(shareslp1);

        uint256 amount0InYieldSource = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource = hook.getAmountInYieldSource(currency1);

        // yield1 decays by 10%
        hook.burnYieldSourcesBalance(currency0, amount0InYieldSource * 10 / 100);
        // yield2 decays by 20%
        hook.burnYieldSourcesBalance(currency1, amount1InYieldSource * 20 / 100);

        BalanceDelta addDeltalp2 = hook.addReHypothecatedLiquidity(shareslp2);

        // in order to obtain the same shares as lp1, lp2 must deposit 10% less currency0 and 20% less currency1
        assertApproxEqAbs(-addDeltalp2.amount0(), -addDeltalp1.amount0() * 90 / 100, 1);
        assertApproxEqAbs(-addDeltalp2.amount1(), -addDeltalp1.amount1() * 80 / 100, 1);

        // total supply should be the sum of the shares
        assertEq(hook.totalSupply(), shareslp1 + shareslp2);
    }

    // -- REMOVING -- //

    function test_remove_uninitialized_reverts() public {
        uint160 hookFlags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        ReHypothecationERC4626Mock newHook = ReHypothecationERC4626Mock(
            payable(address(hookFlags + 0x10000000000000000000000000000000)) // generate a different address
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );
        vm.expectRevert(ReHypothecationHook.NotInitialized.selector);
        newHook.removeReHypothecatedLiquidity(1e15);
    }

    function test_remove_zero_reverts() public {
        vm.expectRevert(ReHypothecationHook.ZeroShares.selector);
        hook.removeReHypothecatedLiquidity(0);
    }

    function testFuzz_remove_singleLP(uint128 shares) public {
        shares = uint128(bound(shares, 1e12, 1e20));

        BalanceDelta addDelta = hook.addReHypothecatedLiquidity(shares);

        uint256 lpAmount0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 lpAmount1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amount0InYieldSource0Before = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource1Before = hook.getAmountInYieldSource(currency1);

        (uint256 amount0, uint256 amount1) = hook.previewRedeem(shares);

        BalanceDelta removeDelta = hook.removeReHypothecatedLiquidity(shares);

        assertEq(-addDelta.amount0(), removeDelta.amount0());
        assertEq(-addDelta.amount1(), removeDelta.amount1());

        assertEq(removeDelta.amount0().toUint256(), amount0, "Delta.amount0() != amount0");
        assertEq(removeDelta.amount1().toUint256(), amount1, "Delta.amount1() != amount1");

        uint256 lpAmount0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 lpAmount1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amount0InYieldSource0After = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource1After = hook.getAmountInYieldSource(currency1);

        assertEq(lpAmount0After, lpAmount0Before + amount0, "lpAmount0After != lpAmount0Before + amount0");
        assertEq(lpAmount1After, lpAmount1Before + amount1, "lpAmount1After != lpAmount1Before + amount1");

        assertEq(
            amount0InYieldSource0After,
            amount0InYieldSource0Before - amount0,
            "amount0InYieldSource0After != amount0InYieldSource0Before + amount0"
        );
        assertEq(
            amount1InYieldSource1After,
            amount1InYieldSource1Before - amount1,
            "amount1InYieldSource1After != amount1InYieldSource1Before + amount1"
        );

        assertEq(hook.balanceOf(address(this)), 0, "Held shares != 0");
        assertEq(hook.totalSupply(), 0, "total shares != 0");
    }

    function test_remove_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        vm.prank(lp1);
        hook.addReHypothecatedLiquidity(shareslp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2);

        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(shareslp1);
        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2);

        // both must have removed the same amount of assets
        assertEq(removeDeltalp1, removeDeltalp2);

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    function test_swap_remove_remove_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        vm.prank(lp1);
        hook.addReHypothecatedLiquidity(shareslp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2);

        swap(key, true, 1e15, ZERO_BYTES);

        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(shareslp1);
        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2);

        // both must have removed the same amount of assets
        assertApproxEqAbs(removeDeltalp1, removeDeltalp2, 1);

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    function test_remove_swap_remove_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        vm.prank(lp1);
        hook.addReHypothecatedLiquidity(shareslp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2);

        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(shareslp1);

        swap(key, true, 1e15, ZERO_BYTES);
        swap(key, false, 1e15 + 1e10, ZERO_BYTES);

        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2);

        // lp2 must have removed more assets, since the fees from the swap belongs to him
        assertGt(removeDeltalp2.amount0(), removeDeltalp1.amount0());
        assertGt(removeDeltalp2.amount1(), removeDeltalp1.amount1());

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    function test_remove_yieldsGrowth_remove_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        vm.prank(lp1);
        hook.addReHypothecatedLiquidity(shareslp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2);

        // lp1 removes
        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(shareslp1);

        uint256 amount0InYieldSource = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource = hook.getAmountInYieldSource(currency1);

        // yield1 grows by 10%
        currency0.transfer(address(yieldSource0), amount0InYieldSource * 10 / 100);
        // yield2 grows by 20%
        currency1.transfer(address(yieldSource1), amount1InYieldSource * 20 / 100);

        // lp2 removes
        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2);

        // lp2 must have removed more assets, since the fees from the yield growth belongs to him
        assertApproxEqAbs(removeDeltalp2.amount0(), removeDeltalp1.amount0() * 110 / 100, 1);
        assertApproxEqAbs(removeDeltalp2.amount1(), removeDeltalp1.amount1() * 120 / 100, 1);

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    function test_remove_yieldsDecay_remove_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        vm.prank(lp1);
        hook.addReHypothecatedLiquidity(shareslp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2);

        // lp1 removes
        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(shareslp1);

        uint256 amount0InYieldSource = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource = hook.getAmountInYieldSource(currency1);

        // yield1 decays by 10%
        hook.burnYieldSourcesBalance(currency0, amount0InYieldSource * 10 / 100);
        // yield2 decays by 20%
        hook.burnYieldSourcesBalance(currency1, amount1InYieldSource * 20 / 100);

        // lp2 removes
        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2);

        // lp2 must have removed less assets, since the yield decay belongs to him
        assertApproxEqAbs(removeDeltalp2.amount0(), removeDeltalp1.amount0() * 90 / 100, 1);
        assertApproxEqAbs(removeDeltalp2.amount1(), removeDeltalp1.amount1() * 80 / 100, 1);

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    // -- differential -- //

    function testFuzz_differential_add_swap_remove_SingleLP(uint256 shares, int256 amountToSwap) public {
        shares = uint256(bound(shares, 1e12, 1e28)); // add from 0.000001 to 10B shares
        amountToSwap = int256(bound(amountToSwap, 1e10, 1e26)); // swap from 0.00000001 to 100M tokens
        // assume the swap is less than half of the added liquidity
        vm.assume(amountToSwap * 2 < int256(shares));

        // -- Add liquidity --
        // Unhooked
        BalanceDelta noHookAddDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), int256(uint256(shares)), 0);
        // Hooked
        BalanceDelta hookedAddDelta = hook.addReHypothecatedLiquidity(shares);
        assertApproxEqAbs(hookedAddDelta, noHookAddDelta, 1, "hookedAddDelta !~= noHookAddDelta");

        // -- Swap --
        // Unhooked
        BalanceDelta noHookSwapDelta = swap(noHookKey, true, amountToSwap, ZERO_BYTES);
        // Hooked
        BalanceDelta hookedSwapDelta = swap(key, true, amountToSwap, ZERO_BYTES);
        assertApproxEqAbs(hookedSwapDelta, noHookSwapDelta, 3, "hookedSwapDelta !~= noHookSwapDelta");

        // -- Remove liquidity --
        // Unhooked
        BalanceDelta noHookRemoveDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), -int256(uint256(shares)), 0);
        // Hooked
        BalanceDelta hookedRemoveDelta = hook.removeReHypothecatedLiquidity(shares);
        assertApproxEqAbs(hookedRemoveDelta, noHookRemoveDelta, 2, "hookedRemoveDelta !~= noHookRemoveDelta");
    }

    // -- decimals/rounding -- //

    function testFuzz_postLossDilutionAttack_add_loss_add_SingleLP(
        uint8 lossPercentage,
        uint128 sharesLP1,
        uint128 sharesLP2
    ) public {
        lossPercentage = uint8(bound(lossPercentage, 1, 99));

        sharesLP1 = uint128(bound(sharesLP1, 1e12, 1e28));
        sharesLP2 = uint128(bound(sharesLP2, 1, 1e28));

        // lp1 adds liquidity
        vm.prank(lp1);
        hook.addReHypothecatedLiquidity(sharesLP1);

        uint256 amount0InYieldSource = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource = hook.getAmountInYieldSource(currency1);

        // the vault suffers a loss
        hook.burnYieldSourcesBalance(currency0, amount0InYieldSource * lossPercentage / 100);
        hook.burnYieldSourcesBalance(currency1, amount1InYieldSource * lossPercentage / 100);

        // preview attacker deposit
        (uint256 amount0, uint256 amount1) = hook.previewMint(sharesLP2);

        // if shares > 0 and amounts are zero, then the attacker can mint shares freely.
        assertFalse(sharesLP2 > 0 && (amount0 == 0 && amount1 == 0));
    }
}
