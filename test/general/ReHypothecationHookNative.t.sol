// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// External imports
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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Internal imports
import {ReHypothecationNativeMock, NativeYieldSourceMock} from "../../src/mocks/ReHypothecationNativeMock.sol";
import {ERC4626YieldSourceMock} from "../../src/mocks/ReHypothecationERC4626Mock.sol";
import {HookTest} from "../../test/utils/HookTest.sol";
import {BalanceDeltaAssertions} from "../../test/utils/BalanceDeltaAssertions.sol";

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
            payable(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)))
        );
        deployCodeTo(
            "src/mocks/ReHypothecationNativeMock.sol:ReHypothecationNativeMock",
            abi.encode(address(yieldSource0), address(yieldSource1)),
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
        uint160 hookFlags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        ReHypothecationNativeMock newHook = ReHypothecationNativeMock(
            payable(address(hookFlags + 0x10000000000000000000000000000000)) // generate a different address
        );
        deployCodeTo(
            "src/mocks/ReHypothecationNativeMock.sol:ReHypothecationNativeMock",
            abi.encode(address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );
        (PoolKey memory nativeKey,) =
            initPool(Currency.wrap(address(0)), currency1, IHooks(address(newHook)), fee, SQRT_PRICE_1_1);
        assertTrue(nativeKey.currency0.isAddressZero());
    }

    // -- DIFFERENTIAL TESTING -- //

    function test_differential_add_swap_remove() public {
        uint256 shares = 1e18;
        int256 amountToSwap = -1e14; // exact input

        // Add liquidity
        BalanceDelta noHookAddDelta = modifyLiquidityRouter.modifyLiquidity{value: 1e18}(
            noHookKey,
            ModifyLiquidityParams({
                tickLower: hook.getTickLower(),
                tickUpper: hook.getTickUpper(),
                liquidityDelta: int256(shares),
                salt: 0
            }),
            ""
        );
        BalanceDelta hookedAddDelta = hook.addReHypothecatedLiquidity{value: 1e18}(shares);
        assertApproxEqAbs(hookedAddDelta, noHookAddDelta, 10, "hookedAddDelta !~= noHookAddDelta");

        // Swap
        BalanceDelta noHookSwapDelta =
            swapNativeInput(noHookKey, true, amountToSwap, ZERO_BYTES, (-amountToSwap).toUint256());
        BalanceDelta hookedSwapDelta = swapNativeInput(key, true, amountToSwap, ZERO_BYTES, (-amountToSwap).toUint256());
        assertApproxEqAbs(hookedSwapDelta, noHookSwapDelta, 10, "hookedSwapDelta !~= noHookSwapDelta");

        // // Remove liquidity
        BalanceDelta noHookRemoveDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), -int256(shares), 0);
        BalanceDelta hookedRemoveDelta = hook.removeReHypothecatedLiquidity(shares);
        assertApproxEqAbs(hookedRemoveDelta, noHookRemoveDelta, 2, "hookedRemoveDelta !~= noHookRemoveDelta");
    }
}
