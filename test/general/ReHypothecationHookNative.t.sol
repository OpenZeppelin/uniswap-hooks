// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// External imports
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
// Internal imports
import {ReHypothecationNativeMock, NativeYieldSourceMock} from "../../src/mocks/general/ReHypothecationNativeMock.sol";
import {ERC4626YieldSourceMock} from "../../src/mocks/general/ReHypothecationERC4626Mock.sol";
import {ReHypothecationHook} from "../../src/general/ReHypothecationHook.sol";
import {CappedERC4626Mock} from "./ReHypothecationHookERC4626.t.sol";
import {HookTest} from "../utils/HookTest.sol";
import {BalanceDeltaAssertions} from "../utils/BalanceDeltaAssertions.sol";

contract ReHypothecationHookNativeTest is HookTest, BalanceDeltaAssertions {
    using StateLibrary for IPoolManager;
    using SafeCast for *;
    using Math for *;

    ReHypothecationNativeMock hook;

    NativeYieldSourceMock yieldSource0;
    ERC4626YieldSourceMock yieldSource1;

    PoolKey noHookKey;

    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");

    uint24 fee = 1000; // 0.1%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        yieldSource0 = new NativeYieldSourceMock();
        yieldSource1 = new ERC4626YieldSourceMock(IERC20(Currency.unwrap(currency1)));

        hook = ReHypothecationNativeMock(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    )
                ))
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationNativeMock.sol:ReHypothecationNativeMock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(hook)
        );

        (key,) = initPool(Currency.wrap(address(0)), currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
        (noHookKey,) = initPool(Currency.wrap(address(0)), currency1, IHooks(address(0)), fee, SQRT_PRICE_1_1);

        vm.label(address(0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");

        _fundNative([address(manager), address(this), lp1, lp2], 1e30);

        _fund([address(manager), address(this), lp1, lp2], [currency1], 1e30);

        _approveCurrencies(
            [address(this), lp1, lp2],
            [currency1],
            [address(manager), address(hook), address(swapRouter), address(modifyLiquidityRouter)]
        );
    }

    function _fundNative(address[4] memory addresses, uint256 amount) internal {
        for (uint256 i = 0; i < addresses.length; i++) {
            deal(addresses[i], amount);
        }
    }

    function _fund(address[4] memory addresses, Currency[1] memory currencies, uint256 amount) internal {
        for (uint256 i = 0; i < addresses.length; i++) {
            for (uint256 j = 0; j < currencies.length; j++) {
                deal(Currency.unwrap(currencies[j]), addresses[i], amount);
            }
        }
    }

    function _approveCurrencies(address[3] memory approvers, Currency[1] memory currencies, address[4] memory spenders)
        internal
    {
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

    function test_initialize_native_currency_supported() public {
        // Native currency (address(0)) should be supported in the native mock
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        ReHypothecationNativeMock newHook = ReHypothecationNativeMock(
            payable(address(hookFlags + 0x10000000000000000000000000000000)) // generate a different address
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationNativeMock.sol:ReHypothecationNativeMock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );
        (PoolKey memory nativeKey,) =
            initPool(Currency.wrap(address(0)), currency1, IHooks(address(newHook)), fee, SQRT_PRICE_1_1);
        assertTrue(nativeKey.currency0.isAddressZero());
    }

    // -- DIFFERENTIAL TESTING -- //

    function test_differential_add_swap_remove() public {
        uint256 liquidity = 1e18;
        int256 amountToSwap = -1e14; // exact input

        // amounts equivalent to `liquidity` at the current price, so the hook's JIT provision matches an
        // equivalent plain pool position.
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(hook.getTickLower()),
            TickMath.getSqrtPriceAtTick(hook.getTickUpper()),
            uint128(liquidity)
        );

        // Add liquidity. `amount0` rounds down, while the pool charges the rounded-up amount, so fund the
        // router with the full `liquidity`-equivalent native value (any excess does not affect the delta).
        BalanceDelta noHookAddDelta = modifyLiquidityRouter.modifyLiquidity{value: liquidity}(
            noHookKey,
            ModifyLiquidityParams({
                tickLower: hook.getTickLower(),
                tickUpper: hook.getTickUpper(),
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );
        (uint256 seedShares, BalanceDelta hookedAddDelta) = hook.seedLiquidity{value: amount0}(amount0, amount1);
        assertApproxEqAbs(hookedAddDelta, noHookAddDelta, 10, "hookedAddDelta !~= noHookAddDelta");

        // Swap
        BalanceDelta noHookSwapDelta =
            swapNativeInput(noHookKey, true, amountToSwap, ZERO_BYTES, (-amountToSwap).toUint256());
        BalanceDelta hookedSwapDelta = swapNativeInput(key, true, amountToSwap, ZERO_BYTES, (-amountToSwap).toUint256());
        assertApproxEqAbs(hookedSwapDelta, noHookSwapDelta, 10, "hookedSwapDelta !~= noHookSwapDelta");

        // Remove liquidity
        BalanceDelta noHookRemoveDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), -int256(liquidity), 0);
        BalanceDelta hookedRemoveDelta = hook.removeReHypothecatedLiquidity(seedShares);
        assertApproxEqAbs(hookedRemoveDelta, noHookRemoveDelta, 1e9, "hookedRemoveDelta !~= noHookRemoveDelta");
    }

    // -- NATIVE YIELD SOURCE -- //

    function test_nativeSource_emptyConvertToAssetsReturnsZero() public {
        NativeYieldSourceMock ys = new NativeYieldSourceMock();
        assertEq(ys.convertToAssets(0), 0, "an empty source should convert to zero assets");
    }

    function test_nativeSource_depositUsesExistingRate() public {
        NativeYieldSourceMock ys = new NativeYieldSourceMock();
        ys.deposit{value: 100}(100, address(this));
        vm.deal(address(ys), 200); // 200 now backs 100 shares (a 2:1 rate)

        address depositor = makeAddr("depositor");
        vm.deal(depositor, 100);
        vm.prank(depositor);
        ys.deposit{value: 100}(100, depositor);

        assertEq(ys.balanceOf(depositor), 50, "shares should be priced at the pre-deposit rate");
    }

    function test_nativeSource_withdrawRejectsSharelessCaller() public {
        NativeYieldSourceMock ys = new NativeYieldSourceMock();
        ys.deposit{value: 1}(1, address(this));
        vm.deal(address(ys), 101); // 101 now backs 1 share

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, attacker, 0, 1));
        ys.withdraw(100, attacker);
    }

    /// @dev Deploys a native hook whose ERC-4626 (currency1) side is capped, seeded with 1e18 of each currency.
    function _deployCappedNativeHook() internal returns (ReHypothecationNativeMock h, CappedERC4626Mock ys1) {
        NativeYieldSourceMock ys0 = new NativeYieldSourceMock();
        ys1 = new CappedERC4626Mock(IERC20(Currency.unwrap(currency1)));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        h = ReHypothecationNativeMock(payable(address(flags + 0x20000000000000000000000000000000)));
        deployCodeTo(
            "src/mocks/general/ReHypothecationNativeMock.sol:ReHypothecationNativeMock",
            abi.encode(address(manager), address(ys0), address(ys1)),
            address(h)
        );
        (key,) = initPool(Currency.wrap(address(0)), currency1, IHooks(address(h)), fee, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency1)).approve(address(h), type(uint256).max);
        h.seedLiquidity{value: 1e18}(1e18, 1e18);
    }

    function test_native_partialMaxWithdraw_swapSucceeds() public {
        (ReHypothecationNativeMock h, CappedERC4626Mock ys1) = _deployCappedNativeHook();

        // Cap the ERC-4626 side well below its backing. Sized by the full backing, this swap would owe more
        // currency1 than the vault lets the hook withdraw.
        uint256 cap = 1e15;
        ys1.setCap(cap);
        assertEq(h.getMaxWithdrawFromYieldSource(currency1), cap, "erc4626 side should be sized by maxWithdraw");

        uint256 balanceBefore = currency1.balanceOf(address(this));
        swapNativeInput(key, true, -1e17, ZERO_BYTES, 1e17);
        uint256 received = currency1.balanceOf(address(this)) - balanceBefore;
        assertGt(received, 0, "swap should deliver currency1");
        assertLe(received, cap, "swap should not take more than the vault can return");
    }

    function test_native_zeroMaxWithdraw_swapReverts() public {
        (ReHypothecationNativeMock h, CappedERC4626Mock ys1) = _deployCappedNativeHook();

        ys1.setCap(0);
        assertEq(h.getMaxWithdrawFromYieldSource(currency1), 0, "erc4626 side should report no withdrawable amount");

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(h),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ReHypothecationHook.NoUsableLiquidity.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapNativeInput(key, true, -1e17, ZERO_BYTES, 1e17);
    }
}
