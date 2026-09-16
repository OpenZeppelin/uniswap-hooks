// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HookTest} from "test/utils/HookTest.sol";
import {AntiSandwichMock} from "src/mocks/general/AntiSandwichMock.sol";
import {AntiSandwichHookHandler} from "../../handlers/AntiSandwichHook/AntiSandwichHookHandler.sol";

/// @dev Campaign for {AntiSandwichHook}. See `AntiSandwichHook.invariants.md`.
contract AntiSandwichHookInvariantsTest is HookTest {
    using StateLibrary for IPoolManager;

    AntiSandwichMock hook;
    AntiSandwichHookHandler handler;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address treasury = makeAddr("treasury");

    /// @dev Outermost tick a swap may reach.
    int24 constant TICK_WINDOW_EDGE = 30000;

    uint256 constant AMOUNT_MIN_BOUND = 1e6;
    uint256 constant AMOUNT_MAX_BOUND = 1e20;

    uint256 constant LIQUIDITY_MIN_BOUND = 1e15;
    uint256 constant LIQUIDITY_MAX_BOUND = 1e21;

    /// @dev Thin position spanning the whole window. Keeps active liquidity non-zero everywhere the price
    /// can reach, so the donating fee handler always has somewhere to donate.
    uint256 constant BACKSTOP_LIQUIDITY = 1e12;

    /// @dev Ceiling for the gas a first swap of a block may consume.
    uint256 constant FIRST_SWAP_GAS_CEILING = 1_000_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = AntiSandwichMock(
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG))
        );
        deployCodeTo(
            "src/mocks/general/AntiSandwichMock.sol:AntiSandwichMock",
            abi.encode(address(manager), treasury),
            address(hook)
        );

        // A zero LP fee leaves the hook as the only thing standing between an attacker and a profit, so a
        // sandwich that loses money here lost it to the mechanism rather than to the pool's own spread.
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 0, 60, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -TICK_WINDOW_EDGE,
                tickUpper: TICK_WINDOW_EDGE,
                liquidityDelta: int256(BACKSTOP_LIQUIDITY),
                salt: bytes32(uint256(1))
            }),
            ZERO_BYTES
        );

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;

        int24[] memory ticks = new int24[](6);
        ticks[0] = -10 * key.tickSpacing;
        ticks[1] = -3 * key.tickSpacing;
        ticks[2] = -key.tickSpacing;
        ticks[3] = key.tickSpacing;
        ticks[4] = 3 * key.tickSpacing;
        ticks[5] = 10 * key.tickSpacing;

        handler = new AntiSandwichHookHandler(
            hook,
            manager,
            swapRouter,
            modifyLiquidityRouter,
            donateRouter,
            key,
            actors,
            ticks,
            AntiSandwichHookHandler.Bounds({
                tickWindowEdge: TICK_WINDOW_EDGE,
                amountMinBound: AMOUNT_MIN_BOUND,
                amountMaxBound: AMOUNT_MAX_BOUND,
                liquidityMinBound: LIQUIDITY_MIN_BOUND,
                liquidityMaxBound: LIQUIDITY_MAX_BOUND
            })
        );

        for (uint256 i; i < actors.length; ++i) {
            _fund(actors[i]);
        }
        _fund(address(handler));

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _fuzzableActions()}));
    }

    function _fuzzableActions() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = AntiSandwichHookHandler.swap.selector;
        selectors[1] = AntiSandwichHookHandler.sandwich.selector;
        selectors[2] = AntiSandwichHookHandler.jitSandwich.selector;
        selectors[3] = AntiSandwichHookHandler.addLiquidity.selector;
        selectors[4] = AntiSandwichHookHandler.removeLiquidity.selector;
        selectors[5] = AntiSandwichHookHandler.donate.selector;
        selectors[6] = AntiSandwichHookHandler.nextBlock.selector;
    }

    function _fund(address who) private {
        IERC20Minimal(Currency.unwrap(currency0)).transfer(who, 1e28);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(who, 1e28);

        vm.startPrank(who);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(donateRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(donateRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev INV-03: no sandwich ends a block ahead. The attack opens and closes the same size in one block,
    /// and the result is valued in currency1 at the price that block was measured against.
    function invariant_ALT03_noSandwichProfits() public view {
        int256 tolerance = handler.sandwichTolerance();

        assertLe(handler.ghost_bestPlainSandwichPnl(), tolerance, "INV-03: a plain sandwich ended a block ahead");
        // A JIT attacker is compared against itself holding the identical position while someone else takes
        // the identical legs. What is left is what swapping bought it, which is what the bound answers for.
        // Liquidity provision itself the umbra design leaves open, and `LiquidityPenaltyHook` addresses it.
        assertLe(handler.ghost_bestJitEdge(), tolerance, "INV-03: swapping beat providing for a JIT attacker");
    }

    /// @dev INV-04: the block's first swap pays no fee. It is measured against the price standing before it
    /// ran, and a swap moves the price away from that, so there is never an improvement to take.
    function invariant_ALT04_theFirstSwapOfABlockPaysNoFee() public view {
        assertEq(handler.ghost_firstSwapFees(), 0, "INV-04: a block's first swap paid a fee");
    }

    /// @dev INV-05: the hook never rejects a swap the pool accepted. The bound is arithmetic over two
    /// amounts a `BalanceDelta` already holds, so no fill exists that it cannot price.
    function invariant_ALT05_theHookRejectsNoSwap() public view {
        assertEq(
            handler.ghost_hookRejections(),
            0,
            string.concat(
                "INV-05: the hook rejected a swap the pool accepted: ", vm.toString(handler.ghost_lastRejection())
            )
        );
    }

    /// @dev INV-06: the checkpoint never claims a block that has not happened.
    function invariant_ALT06_theCheckpointNeverClaimsAFutureBlock() public view {
        assertLe(uint256(handler.checkpointBlock()), block.number, "INV-06: the checkpoint claims a future block");
    }

    /// @dev INV-07: a checkpoint that claims the current block holds a price.
    function invariant_ALT07_aClaimedCheckpointHoldsAPrice() public view {
        if (handler.checkpointBlock() != uint48(block.number)) return;

        assertGt(uint256(handler.checkpointPrice()), 0, "INV-07: the checkpoint claims the block with no price");
    }

    /// @dev INV-08: every wei the bound charged reached the fee recipient, and none of it rests in the hook
    /// or leaks back to whoever paid it.
    function invariant_ALT08_everyFeeReachesTheRecipient() public view {
        assertEq(
            IERC6909Claims(address(manager)).balanceOf(treasury, currency0.toId()),
            handler.ghost_totalFee0(),
            "INV-08: the recipient's currency0 claims do not match the fees charged"
        );
        assertEq(
            IERC6909Claims(address(manager)).balanceOf(treasury, currency1.toId()),
            handler.ghost_totalFee1(),
            "INV-08: the recipient's currency1 claims do not match the fees charged"
        );
        assertEq(
            IERC6909Claims(address(manager)).balanceOf(address(hook), currency0.toId()),
            0,
            "INV-08: the hook kept currency0 claims"
        );
        assertEq(
            IERC6909Claims(address(manager)).balanceOf(address(hook), currency1.toId()),
            0,
            "INV-08: the hook kept currency1 claims"
        );
    }

    /// @dev INV-09: a swap costs the same whatever the price did since the last block. The checkpoint is one
    /// slot and nothing the hook reads scales with the distance the price travelled.
    function invariant_ALT09_theCheckpointRefreshIsBounded() public view {
        assertLt(
            handler.ghost_maxFirstSwapGas(),
            FIRST_SWAP_GAS_CEILING,
            "INV-09: a first swap of a block scaled with the distance the price travelled"
        );
    }

    /// @dev Per-sequence coverage. Without these the invariants above can hold vacuously.
    function afterInvariant() public view {
        console.log("--- actions ---");
        console.log("swap          ", handler.calls("swap"));
        console.log("sandwich      ", handler.calls("sandwich"));
        console.log("jitSandwich   ", handler.calls("jitSandwich"));
        console.log("addLiquidity  ", handler.calls("addLiquidity"));
        console.log("removeLiquidity", handler.calls("removeLiquidity"));
        console.log("donate        ", handler.calls("donate"));
        console.log("nextBlock     ", handler.calls("nextBlock"));

        console.log("--- states ---");
        console.log("bound checks           ", handler.ghost_boundChecks());
        console.log("swaps that paid a fee  ", handler.ghost_feeCharges());
        console.log("first swaps of a block ", handler.ghost_firstSwapsOfBlock());
        console.log("blocks with two or more", handler.ghost_multiSwapBlocks());
        console.log("sandwiches measured    ", handler.ghost_sandwichesMeasured());
        console.log("jit sandwiches measured", handler.ghost_jitSandwichesMeasured());
        console.log("max first swap gas     ", handler.ghost_maxFirstSwapGas());

        assertGt(handler.calls("swap"), 0, "swap was not exercised");
        assertGt(handler.calls("sandwich"), 0, "sandwich was not exercised");
        assertGt(handler.calls("jitSandwich"), 0, "jitSandwich was not exercised");
        assertGt(handler.calls("addLiquidity"), 0, "addLiquidity was not exercised");
        assertGt(handler.calls("removeLiquidity"), 0, "removeLiquidity was not exercised");
        assertGt(handler.calls("donate"), 0, "donate was not exercised");
        assertGt(handler.calls("nextBlock"), 0, "nextBlock was not exercised");

        assertGt(handler.ghost_boundChecks(), 0, "INV-01 was never asserted");
        assertGt(handler.ghost_feeCharges(), 0, "no swap ever paid a fee, so the bound never bound");
        assertGt(handler.ghost_multiSwapBlocks(), 0, "no block saw more than one swap");
        assertGt(handler.ghost_sandwichesMeasured(), 0, "no sandwich was measured end to end");
        assertGt(handler.ghost_jitSandwichesMeasured(), 0, "no JIT sandwich was measured, so half of INV-03 is vacuous");
        assertGt(handler.ghost_firstSwapsOfBlock(), 0, "no swap was the first of its block, so INV-04 is vacuous");
    }
}
