// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ReHypothecationHook} from "src/general/ReHypothecationHook.sol";
import {ReHypothecationMock, ERC4626Mock} from "src/mocks/ReHypothecationMock.sol";
import {HookTest} from "../utils/HookTest.sol";
import {BalanceDeltaAssertions} from "../utils/BalanceDeltaAssertions.sol";
import {IERC4626} from "openzeppelin/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

contract ReHypothecationHookTest is HookTest, BalanceDeltaAssertions {
    using StateLibrary for IPoolManager;

    ReHypothecationMock hook;
    uint24 fee = 1000; // 0.1%

    IERC4626 yieldSource0;
    IERC4626 yieldSource1;

    PoolKey noHookKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        yieldSource0 = IERC4626(new ERC4626Mock(IERC20(Currency.unwrap(currency0)), "Yield Source 0", "Y0"));
        yieldSource1 = IERC4626(new ERC4626Mock(IERC20(Currency.unwrap(currency1)), "Yield Source 1", "Y1"));

        hook = ReHypothecationMock(
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG))
        );
        deployCodeTo("src/mocks/ReHypothecationMock.sol:ReHypothecationMock", abi.encode(manager), address(hook));

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
        (noHookKey,) = initPool(currency0, currency1, IHooks(address(0)), fee, SQRT_PRICE_1_1);

        hook.setYieldSources(address(yieldSource0), address(yieldSource1));

        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");
    }

    function test_already_initialized_reverts() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
    }

    function test_full_cycle() public {
        uint128 liquidity = 1e15;
        BalanceDelta delta = hook.addReHypothecatedLiquidity(liquidity);

        assertEq(
            IERC4626(address(yieldSource0)).balanceOf(address(hook)),
            uint256(liquidity),
            "YieldSource0 balance should be the same as the liquidity"
        );
        assertEq(
            IERC4626(address(yieldSource1)).balanceOf(address(hook)),
            uint256(liquidity),
            "YieldSource1 balance should be the same as the liquidity"
        );

        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity should be 0");

        assertEq(hook.balanceOf(address(this)), liquidity, "Hook balance should be the same as the liquidity");

        // add rehypothecated liquidity should be equal to modifyPoolLiquidity with a pool with the same state
        BalanceDelta expectedDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), int256(uint256(liquidity)), 0);
        assertEq(delta, expectedDelta, "Delta should be equal");

        BalanceDelta swapDelta = swap(key, false, 1e14, ZERO_BYTES);
        BalanceDelta noHookSwapDelta = swap(noHookKey, false, 1e14, ZERO_BYTES);

        assertEq(swapDelta, noHookSwapDelta, "Swap delta should be equal");
        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity should be 0");

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "Currency0 balance should be 0");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "Currency1 balance should be 0");

        assertApproxEqAbs(
            IERC4626(address(yieldSource0)).balanceOf(address(hook)),
            uint256(liquidity - uint128(swapDelta.amount0())),
            2,
            "YieldSource0 balance should go to user"
        );
        assertApproxEqAbs(
            IERC4626(address(yieldSource1)).balanceOf(address(hook)),
            uint256(uint128(int128(liquidity) - swapDelta.amount1())),
            2,
            "YieldSource1 balance should go to user"
        );

        delta = hook.removeReHypothecatedLiquidity(address(this));

        expectedDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), int256(-int128(liquidity)), 0);

        assertEq(delta, expectedDelta, "Delta should be equal");

        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity should be 0");

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "Currency0 balance should be 0");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "Currency1 balance should be 0");

        assertEq(IERC4626(address(yieldSource0)).balanceOf(address(hook)), 0, "YieldSource0 balance should be 0");
        assertEq(IERC4626(address(yieldSource1)).balanceOf(address(hook)), 0, "YieldSource1 balance should be 0");

        assertEq(hook.balanceOf(address(this)), 0, "Hook balance should be 0");
    }

    function test_swap_with_increased_shares() public {
        uint128 liquidity = 1e15;
        BalanceDelta delta = hook.addReHypothecatedLiquidity(liquidity);

        IERC20(Currency.unwrap(currency0)).transfer(address(yieldSource0), 1e14); // 10% increase on currency0
        IERC20(Currency.unwrap(currency1)).transfer(address(yieldSource1), 1e14); // 10% increase on currency1

        assertEq(
            IERC4626(address(yieldSource0)).balanceOf(address(hook)),
            uint256(liquidity),
            "YieldSource0 balance should be the same as the liquidity"
        );
        assertEq(
            IERC4626(address(yieldSource1)).balanceOf(address(hook)),
            uint256(liquidity),
            "YieldSource1 balance should be the same as the liquidity"
        );

        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity should be 0");

        assertEq(hook.balanceOf(address(this)), liquidity, "Hook balance should be the same as the liquidity");

        // add rehypothecated liquidity should be equal to modifyPoolLiquidity with a pool with the same state
        BalanceDelta expectedDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), int256(uint256(liquidity)), 0);
        assertEq(delta, expectedDelta, "Delta should be equal");

        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity should be 0");

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "Currency0 balance should be 0");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "Currency1 balance should be 0");

        delta = hook.removeReHypothecatedLiquidity(address(this));

        expectedDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), int256(-int128(liquidity)), 0);

        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity should be 0");

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "Currency0 balance should be 0");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "Currency1 balance should be 0");

        assertEq(IERC4626(address(yieldSource0)).balanceOf(address(hook)), 0, "YieldSource0 balance should be 0");
        assertEq(IERC4626(address(yieldSource1)).balanceOf(address(hook)), 0, "YieldSource1 balance should be 0");

        assertEq(hook.balanceOf(address(this)), 0, "Hook balance should be 0");
    }

    function test_add_rehypothecated_liquidity_zero_liquidity_reverts() public {
        vm.expectRevert(ReHypothecationHook.ZeroLiquidity.selector);
        hook.addReHypothecatedLiquidity(0);
    }

    function test_add_rehypothecated_liquidity_uninitialized_pool_key_reverts() public {
        ReHypothecationMock newHook = ReHypothecationMock(
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) + 2 ** 96)
        );

        deployCodeTo(
            "src/mocks/ReHypothecationMock.sol:ReHypothecationMock",
            abi.encode(manager, address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );
        vm.expectRevert(ReHypothecationHook.PoolKeyNotInitialized.selector);
        newHook.addReHypothecatedLiquidity(1e15);
    }

    function test_add_rehypothecated_liquidity_msg_value_reverts() public {
        vm.expectRevert(ReHypothecationHook.InvalidMsgValue.selector);
        hook.addReHypothecatedLiquidity{value: 1e5}(1e15);
    }

    function test_remove_rehypothecated_liquidity_zero_liquidity_reverts() public {
        vm.expectRevert(ReHypothecationHook.ZeroLiquidity.selector);
        hook.removeReHypothecatedLiquidity(address(this));
    }

    function test_remove_rehypothecated_liquidity_uninitialized_pool_key_reverts() public {
        ReHypothecationMock newHook = ReHypothecationMock(
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) + 2 ** 96)
        );

        deployCodeTo(
            "src/mocks/ReHypothecationMock.sol:ReHypothecationMock",
            abi.encode(manager, address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );
        vm.expectRevert(ReHypothecationHook.PoolKeyNotInitialized.selector);
        newHook.removeReHypothecatedLiquidity(address(this));
    }

    function test_add_rehypothecated_liquidity_invalid_currency_reverts() public {
        ReHypothecationMock newHook = ReHypothecationMock(
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) + 2 ** 96)
        );

        deployCodeTo(
            "src/mocks/ReHypothecationMock.sol:ReHypothecationMock",
            abi.encode(manager, address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );

        initPool(Currency.wrap(address(0)), currency1, IHooks(address(newHook)), fee, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency1)).approve(address(newHook), type(uint256).max);

        vm.expectRevert(ReHypothecationHook.InvalidCurrency.selector);
        newHook.addReHypothecatedLiquidity{value: 1e15}(1e15);
    }

    function test_add_rehypothecated_liquidity_native_reverts() public {
        ReHypothecationMock newHook = ReHypothecationMock(
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) + 2 ** 96)
        );

        deployCodeTo(
            "src/mocks/ReHypothecationMock.sol:ReHypothecationMock",
            abi.encode(manager, address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );

        initPool(Currency.wrap(address(0)), currency1, IHooks(address(newHook)), fee, SQRT_PRICE_1_1);

        vm.expectRevert(ReHypothecationHook.InvalidMsgValue.selector);
        newHook.addReHypothecatedLiquidity{value: 1e14}(1e15);
    }
}
