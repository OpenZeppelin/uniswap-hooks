// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
// Internal imports
import {LimitOrderHook, OrderIdLibrary} from "src/general/LimitOrderHook.sol";
import {LimitOrderHookMock} from "src/mocks/general/LimitOrderHookMock.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {HookTest} from "../utils/HookTest.sol";

/// @dev Calls {CurrencySettler-settle} directly, to reach the library from outside a hook.
contract CurrencySettlerMock {
    function settleNative(IPoolManager poolManager, address payer, uint256 amount) external {
        CurrencySettler.settle(Currency.wrap(address(0)), poolManager, payer, amount, false);
    }
}

contract LimitOrderHookNativeTest is HookTest {
    LimitOrderHookMock hook;

    address user = makeAddr("user");
    address swapper = makeAddr("swapper");
    address attacker = makeAddr("attacker");

    int24 tickSpacing;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = LimitOrderHookMock(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));
        deployCodeTo(
            "src/mocks/general/LimitOrderHookMock.sol:LimitOrderHookMock", abi.encode(address(manager)), address(hook)
        );

        (nativeKey,) = initPool(Currency.wrap(address(0)), currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        tickSpacing = nativeKey.tickSpacing;

        address[3] memory holders = [user, swapper, attacker];
        for (uint256 i = 0; i < holders.length; i++) {
            deal(holders[i], 1e24);
            IERC20Minimal(Currency.unwrap(currency1)).transfer(holders[i], 1e30);

            vm.startPrank(holders[i]);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
            vm.stopPrank();
        }

        deal(address(this), 1e24);
    }

    /// @dev The placer settles the currency their order sells, and the native currency is paid from the
    /// hook's balance rather than theirs. The hook serves no pool holding it, in either direction, so
    /// whatever balance it holds stays where it is.
    function test_placeOrder_native_reverts() public {
        uint256 seeded = 5 ether;
        vm.deal(address(hook), seeded);

        vm.prank(attacker);
        vm.expectRevert(LimitOrderHook.NativeCurrencyUnsupported.selector);
        hook.placeOrder(nativeKey, tickSpacing, true, 1e18);

        vm.prank(attacker);
        vm.expectRevert(LimitOrderHook.NativeCurrencyUnsupported.selector);
        hook.placeOrder(nativeKey, -tickSpacing, false, 1e18);

        assertEq(address(hook).balance, seeded, "no placement should reach the hook's balance");
        assertEq(rawOrderIdOf(nativeKey, tickSpacing, true), 0, "no sell order should exist");
        assertEq(rawOrderIdOf(nativeKey, -tickSpacing, false), 0, "no buy order should exist");
    }

    /// @dev The library pays the native currency from the balance of the calling contract, so settling it
    /// for anyone else would spend a balance that payer never provided.
    function test_settle_nativeForAnotherPayer_reverts() public {
        CurrencySettlerMock settler = new CurrencySettlerMock();

        vm.expectRevert(abi.encodeWithSelector(CurrencySettler.InvalidNativePayer.selector, attacker));
        settler.settleNative(manager, attacker, 1 ether);
    }

    function rawOrderIdOf(PoolKey memory poolKey, int24 tickLower, bool zeroForOne) internal view returns (uint232) {
        return OrderIdLibrary.OrderId.unwrap(hook.getOrderId(poolKey, tickLower, zeroForOne));
    }
}
