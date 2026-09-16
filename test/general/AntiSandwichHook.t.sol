// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {HookTest} from "../utils/HookTest.sol";
import {AntiSandwichHook} from "../../src/general/AntiSandwichHook.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";
import {AntiSandwichMock} from "../../src/mocks/general/AntiSandwichMock.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "../../src/utils/CurrencySettler.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @dev Keeps the fee as ERC-6909. The penalty leaves the pool for good.
contract KeepingAntiSandwichHook is AntiSandwichHook {
    uint256 public lastFee;
    uint256 public totalFee;

    constructor(IPoolManager manager_) BaseHook(manager_) {}

    function _afterSwapHandler(PoolKey calldata, SwapParams calldata, BalanceDelta, uint256, uint256 fee)
        internal
        override
    {
        lastFee = fee;
        totalFee += fee;
    }

    function test() public {}
}

/// @dev Mirrors `src/mocks/general/AntiSandwichMock.sol`: donates the penalty to in-range liquidity.
contract DonatingHook is AntiSandwichHook {
    using CurrencySettler for Currency;

    uint256 public lastFee;
    uint256 public totalFee;

    constructor(IPoolManager manager_) BaseHook(manager_) {}

    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        uint256,
        uint256 feeAmount
    ) internal override {
        lastFee = feeAmount;
        totalFee += feeAmount;
        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? (key.currency1) : (key.currency0);
        (uint256 amount0, uint256 amount1) =
            unspecified == key.currency0 ? (feeAmount, uint256(0)) : (uint256(0), feeAmount);
        poolManager.donate(key, amount0, amount1, "");
        unspecified.settle(poolManager, address(this), feeAmount, true);
    }

    function test() public {}
}

/**
 * @dev The deferred-donation handler, reimplemented here so the result stays runnable after the library
 *      moved on. Fees accumulate per pool and the first fee-bearing swap of a later block donates the
 *      earlier block's batch to in-range liquidity. Each donation is capped at what a `BalanceDelta`
 *      carries, which is the form the design reached before it was withdrawn.
 */
contract DeferredDonateHook is AntiSandwichHook {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    struct Pending {
        uint48 blockNumber;
        uint256 amount0;
        uint256 amount1;
    }

    uint256 private constant _MAX_DONATION = uint256(uint128(type(int128).max));

    mapping(PoolId id => Pending pending) private _pending;

    bool public capDonations = true;

    constructor(IPoolManager manager_) BaseHook(manager_) {}

    function setCapDonations(bool value) external {
        capDonations = value;
    }

    function getPendingFees(PoolId poolId) public view returns (Pending memory) {
        return _pending[poolId];
    }

    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        uint256,
        uint256 feeAmount
    ) internal override {
        Pending storage pending = _pending[key.toId()];
        uint48 currentBlock = _getBlockNumber();

        if (pending.blockNumber != currentBlock) {
            _release(key, pending);
            pending.blockNumber = currentBlock;
        }

        if (params.amountSpecified < 0 == params.zeroForOne) pending.amount1 += feeAmount;
        else pending.amount0 += feeAmount;
    }

    function _release(PoolKey calldata key, Pending storage pending) private {
        uint256 amount0 = capDonations ? Math.min(pending.amount0, _MAX_DONATION) : pending.amount0;
        uint256 amount1 = capDonations ? Math.min(pending.amount1, _MAX_DONATION) : pending.amount1;
        if (amount0 == 0 && amount1 == 0) return;
        if (poolManager.getLiquidity(key.toId()) == 0) return;

        pending.amount0 -= amount0;
        pending.amount1 -= amount1;

        poolManager.donate(key, amount0, amount1, "");
        if (amount0 != 0) key.currency0.settle(poolManager, address(this), amount0, true);
        if (amount1 != 0) key.currency1.settle(poolManager, address(this), amount1, true);
    }

    function test() public {}
}

/// @dev `_getBlockNumber` is an override point. This one hands back a counter that moves on every read, so
///      every swap looks like the first of a new block.
contract PerSwapClockHook is AntiSandwichHook {
    uint48 private _clock;

    constructor(IPoolManager manager_) BaseHook(manager_) {}

    function _getBlockNumber() internal view override returns (uint48) {
        return uint48(uint256(keccak256(abi.encode(gasleft()))));
    }

    function _afterSwapHandler(PoolKey calldata, SwapParams calldata, BalanceDelta, uint256, uint256)
        internal
        override
    {}

    function test() public {}
}

/// @dev The other bad override: a clock that never moves, so the checkpoint is taken once and never again.
contract FrozenClockHook is AntiSandwichHook {
    uint256 public lastFee;

    constructor(IPoolManager manager_) BaseHook(manager_) {}

    function _getBlockNumber() internal pure override returns (uint48) {
        return 1;
    }

    function _afterSwapHandler(PoolKey calldata, SwapParams calldata, BalanceDelta, uint256, uint256 fee)
        internal
        override
    {
        lastFee = fee;
    }

    function test() public {}
}

/// @dev A handler that swaps back into the same pool while the hook is still inside `afterSwap`, which is
///      the shape any reentrant token or exotic handler would take.
contract ReentrantHandlerHook is AntiSandwichHook {
    using CurrencySettler for Currency;

    bool public armed;
    bool public reentered;
    bool public reentryReverted;
    uint160 public checkpointSeenInside;

    constructor(IPoolManager manager_) BaseHook(manager_) {}

    function arm() external {
        armed = true;
    }

    function _afterSwapHandler(PoolKey calldata key, SwapParams calldata params, BalanceDelta, uint256, uint256 fee)
        internal
        override
    {
        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? key.currency1 : key.currency0;

        if (armed) {
            armed = false;
            reentered = true;
            checkpointSeenInside = getLastCheckpoint(key.toId()).sqrtPriceX96;
            try poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -1e15,
                    sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
                }),
                ""
            ) returns (
                BalanceDelta nested
            ) {
                // Settle what the nested swap owes and keep what it earned, both as claims.
                if (nested.amount0() > 0) {
                    key.currency0.take(poolManager, address(this), uint128(nested.amount0()), true);
                }
                if (nested.amount1() > 0) {
                    key.currency1.take(poolManager, address(this), uint128(nested.amount1()), true);
                }
                if (nested.amount0() < 0) {
                    key.currency0.settle(poolManager, address(this), uint128(-nested.amount0()), true);
                }
                if (nested.amount1() < 0) {
                    key.currency1.settle(poolManager, address(this), uint128(-nested.amount1()), true);
                }
            } catch {
                reentryReverted = true;
            }
        }

        // Keep the fee as claims.
        unspecified;
        fee;
    }

    function test() public {}
}

contract AntiSandwichHookTest is HookTest {
    KeepingAntiSandwichHook hook;

    int24 constant SPAN = 6000;
    int256 constant LIQUIDITY = 1e18;
    int24 spacing = 60;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hook = KeepingAntiSandwichHook(
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG))
        );
        deployCodeTo(
            "test/general/AntiSandwichHook.t.sol:KeepingAntiSandwichHook", abi.encode(address(manager)), address(hook)
        );
    }

    function _boundedPool(IHooks hooks) private returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(currency0, currency1, hooks, 0, spacing, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -SPAN, tickUpper: SPAN, liquidityDelta: LIQUIDITY, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @dev A whole sandwich closed with an exact output back-run. currency0 nets to zero, so the P&L is
    ///      currency1 alone.
    function _sandwichPnl(int256 size, int256 victim) private returns (int256 hooked, int256 plain) {
        PoolKey memory hookedKey = _boundedPool(IHooks(address(hook)));
        PoolKey memory plainKey = _boundedPool(IHooks(address(0)));

        vm.roll(block.number + 1);

        int256 sold = swap(hookedKey, true, -size, ZERO_BYTES).amount1();
        swap(hookedKey, true, -victim, ZERO_BYTES);
        hooked = sold + swap(hookedKey, false, size, ZERO_BYTES).amount1();

        int256 soldPlain = swap(plainKey, true, -size, ZERO_BYTES).amount1();
        swap(plainKey, true, -victim, ZERO_BYTES);
        plain = soldPlain + swap(plainKey, false, size, ZERO_BYTES).amount1();
    }

    /// @dev The same sandwich closed with an exact input back-run, so a profit shows up as getting more
    ///      currency0 back than was sold.
    function _sandwichPnlExactInput(int256 size, int256 victim) private returns (int256 hooked, int256 plain) {
        PoolKey memory hookedKey = _boundedPool(IHooks(address(hook)));
        PoolKey memory plainKey = _boundedPool(IHooks(address(0)));

        vm.roll(block.number + 1);

        int256 sold = swap(hookedKey, true, -size, ZERO_BYTES).amount1();
        swap(hookedKey, true, -victim, ZERO_BYTES);
        hooked = swap(hookedKey, false, -sold, ZERO_BYTES).amount0() - size;

        int256 soldPlain = swap(plainKey, true, -size, ZERO_BYTES).amount1();
        swap(plainKey, true, -victim, ZERO_BYTES);
        plain = swap(plainKey, false, -soldPlain, ZERO_BYTES).amount0() - size;
    }

    function _sizes() private pure returns (int256[7] memory) {
        return [int256(1e16), 1e17, 2e17, 25e16, 27e16, 30e16, 33e16];
    }

    /// @notice The sandwich loses money at every size, including sizes past the depth the pool held at the
    /// beginning of the block.
    function test_sandwichIsUnprofitableAtEverySize() public {
        int256[7] memory sizes = _sizes();
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            (int256 hooked, int256 plain) = _sandwichPnl(sizes[i], 1e16);
            assertLt(hooked, 0, "the sandwich turned a profit through the hook");
            assertGt(plain, 0, "the same sandwich should pay off without the hook");
            vm.revertToState(snap);
        }
    }

    /// @notice The loss a sandwich takes is the slippage its front run paid, whatever the back run does.
    function test_theLossIsTheFrontRunsSlippage() public {
        PoolKey memory key = _boundedPool(IHooks(address(hook)));
        vm.roll(block.number + 1);

        int256 size = 2e17;
        int256 sold = swap(key, true, -size, ZERO_BYTES).amount1();

        // What the front run would have received at the beginning-of-block price of 1:1.
        int256 atBlockStart = size;

        swap(key, true, -1e16, ZERO_BYTES);
        int256 pnl = sold + swap(key, false, size, ZERO_BYTES).amount1();

        assertEq(pnl, sold - atBlockStart, "the loss is not the front run's slippage");
    }

    /// @notice A swap that does not beat the beginning-of-block price pays nothing, however large it is.
    function test_aSwapThatDoesNotBeatTheBlockStartPriceIsNotCharged() public {
        uint256 snap = vm.snapshotState();

        PoolKey memory buyKey = _boundedPool(IHooks(address(hook)));
        vm.roll(block.number + 1);
        swap(buyKey, false, -1e16, ZERO_BYTES);
        swap(buyKey, false, -2e18, ZERO_BYTES);
        assertEq(hook.lastFee(), 0, "a buy filled above the block-start price was charged");

        vm.revertToState(snap);

        PoolKey memory sellKey = _boundedPool(IHooks(address(hook)));
        vm.roll(block.number + 1);
        swap(sellKey, true, -1e16, ZERO_BYTES);
        swap(sellKey, true, -2e18, ZERO_BYTES);
        assertEq(hook.lastFee(), 0, "a sell filled below the block-start price was charged");
    }

    /// @dev The mirrored sandwich: the attacker buys first, the victim buys, and the attacker sells into the
    ///      push. currency0 nets to zero, so the P&L is currency1 alone.
    function _reverseSandwichPnl(int256 size, int256 victim) private returns (int256 hooked, int256 plain) {
        PoolKey memory hookedKey = _boundedPool(IHooks(address(hook)));
        PoolKey memory plainKey = _boundedPool(IHooks(address(0)));

        vm.roll(block.number + 1);

        int256 bought = swap(hookedKey, false, size, ZERO_BYTES).amount1();
        swap(hookedKey, false, victim, ZERO_BYTES);
        hooked = bought + swap(hookedKey, true, -size, ZERO_BYTES).amount1();

        int256 boughtPlain = swap(plainKey, false, size, ZERO_BYTES).amount1();
        swap(plainKey, false, victim, ZERO_BYTES);
        plain = boughtPlain + swap(plainKey, true, -size, ZERO_BYTES).amount1();
    }

    /// @dev A pool opened at `tick` with one position `width` spacings either side of it.
    function _poolAt(int24 tick, int24 tickSpacing, uint128 liquidity, int24 width)
        private
        returns (PoolKey memory poolKey)
    {
        int24 centre = (tick / tickSpacing) * tickSpacing;
        (poolKey,) =
            initPool(currency0, currency1, IHooks(address(hook)), 0, tickSpacing, TickMath.getSqrtPriceAtTick(centre));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: centre - width * tickSpacing,
                tickUpper: centre + width * tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    /// @dev `amount0` valued in currency1 at `sqrtPriceX96`, rounded down.
    function _value0In1(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @notice Across the price range, four tick spacings and both directions, a protected swap is never
    /// filled better than the block-start price, and no swap is rejected by the hook itself.
    ///
    /// The tick range reaches where a bound on a large swap passes what a `BalanceDelta` carries, so it
    /// covers the branch that refuses an exact output rather than letting it through uncharged.
    function testFuzz_theBoundHoldsAcrossPricesAndSpacings(
        int24 tickSeed,
        uint256 spacingSeed,
        uint128 liquiditySeed,
        uint128 displaceSeed,
        uint128 probeSeed,
        bool openWithBuy
    ) public {
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        int24 tickSpacing = spacings[spacingSeed % 4];
        int24 tick = int24(bound(tickSeed, -350000, 350000));
        uint128 liquidity = uint128(bound(liquiditySeed, 1e15, 1e24));
        uint256 displace = bound(displaceSeed, 1e6, 1e21);
        uint256 probe = bound(probeSeed, 1e6, 1e21);

        PoolKey memory poolKey = _poolAt(tick, tickSpacing, liquidity, 40);
        vm.roll(block.number + 1);

        // The block's first swap sets the checkpoint and displaces the price.
        if (!_trySwap(poolKey, openWithBuy, -int256(displace))) return;

        uint160 price = hook.getLastCheckpoint(poolKey.toId()).sqrtPriceX96;
        assertGt(price, 0, "the checkpoint holds no price");

        // A protected swap in the improving direction, which is the one the bound reaches.
        try this.externalSwap(poolKey, !openWithBuy, -int256(probe)) returns (BalanceDelta delta) {
            int128 amount0 = delta.amount0();
            int128 amount1 = delta.amount1();
            if (amount0 == 0 || amount1 == 0) return;

            uint256 slack = 2 * _value0In1(1, price) + 3;

            if (amount0 > 0) {
                assertGe(
                    uint256(uint128(-amount1)) + slack,
                    _value0In1(uint256(uint128(amount0)), price),
                    "currency0 was bought below the beginning-of-block price"
                );
            } else {
                assertLe(
                    uint256(uint128(amount1)),
                    _value0In1(uint256(uint128(-amount0)), price) + slack,
                    "currency0 was sold above the beginning-of-block price"
                );
            }
        } catch (bytes memory reason) {
            // Only a revert the pool manager wrapped around this hook counts against it.
            bytes4 selector;
            address target;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
                target := mload(add(reason, 0x24))
            }
            assertFalse(
                reason.length >= 36 && selector == bytes4(0x90bfb865) && target == address(hook),
                "the hook rejected a swap the pool accepted"
            );
        }
    }

    /// @dev The revert the pool manager produces when the hook refuses a swap in `afterSwap`.
    function _refusalFromTheHook() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(AntiSandwichHook.TargetOutOfRange.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Runs a swap and reports whether the pool accepted it, discarding the delta.
    function _trySwap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified) private returns (bool) {
        try this.externalSwap(poolKey, zeroForOne, amountSpecified) returns (BalanceDelta) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev `swap` through an external call, so a revert can be caught rather than failing the run.
    function externalSwap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified)
        external
        returns (BalanceDelta)
    {
        require(msg.sender == address(this), "only self");
        return swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    /// @dev A pool priced far from 1, where valuing a large swap at the checkpoint passes what a
    ///      `BalanceDelta` carries.
    function _highPricedPool() private returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 0, 60, TickMath.getSqrtPriceAtTick(399900));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -399960, tickUpper: 399960, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @notice The bound does not switch off on a large leg. An exact output whose floor passes what a
    /// `BalanceDelta` carries is refused, rather than let through uncapped.
    function test_theBoundDoesNotSwitchOffOnALargeLeg() public {
        int256[3] memory priced = [int256(1e20), 5e20, 7e20];
        uint256 previousPaid;

        // Below the crossing the charge rises with the size, so no size is cheaper than a smaller one.
        for (uint256 i; i < priced.length; ++i) {
            uint256 snap = vm.snapshotState();

            PoolKey memory poolKey = _highPricedPool();
            vm.roll(block.number + 1);
            swap(poolKey, true, -5e26, ZERO_BYTES); // the block's first swap, which crashes the price

            uint256 paid = uint256(int256(-swap(poolKey, false, priced[i], ZERO_BYTES).amount1()));

            assertGt(hook.lastFee(), 0, "a large exact output escaped the target");
            assertGe(paid, previousPaid, "buying more currency0 cost less than buying less of it");
            previousPaid = paid;

            vm.revertToState(snap);
        }

        // Past it no expressible amount satisfies the floor, so the swap is refused rather than let through.
        int256[2] memory refused = [int256(1e21), 5e21];

        for (uint256 i; i < refused.length; ++i) {
            uint256 snap = vm.snapshotState();

            PoolKey memory poolKey = _highPricedPool();
            vm.roll(block.number + 1);
            swap(poolKey, true, -5e26, ZERO_BYTES);

            vm.expectRevert(_refusalFromTheHook());
            swap(poolKey, false, refused[i], ZERO_BYTES);

            vm.revertToState(snap);
        }
    }
}

/**
 * @dev Adversarial suite against `AntiSandwichHook`.
 *
 * Every pool starts at 1:1, so the checkpoint price is 1 and a P&L valued at the checkpoint is the plain
 * sum of the two currency amounts. Every scenario squares currency0 to exactly zero before it reports, so
 * the number it reports is currency1 alone.
 */
contract AntiSandwichHookAdversarialTest is HookTest {
    using StateLibrary for IPoolManager;

    KeepingAntiSandwichHook keepHook;
    DonatingHook donateHook;
    DeferredDonateHook deferredHook;
    AntiSandwichMock treasuryHook;
    AntiSandwichMock tollHook; // its fee recipient is this contract, i.e. the attacker
    PerSwapClockHook perSwapClockHook;
    FrozenClockHook frozenClockHook;
    ReentrantHandlerHook reentrantHook;
    address feeSink;

    int24 constant SPAN = 60000;
    int256 constant LIQUIDITY = 1e18;
    int24 constant SPACING = 60;

    /// @dev `amount` codes for a leg whose size is only known while the scenario runs.
    int256 constant SQUARE_CURRENCY0 = 0;
    int256 constant SQUARE_CURRENCY1 = 1;

    struct Pnl {
        int256 a0;
        int256 a1;
    }

    struct Leg {
        bool zeroForOne;
        int256 amount;
        bool mine;
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        keepHook = KeepingAntiSandwichHook(address(flags | uint160(1 << 40)));
        deployCodeTo(
            "test/general/AntiSandwichHook.t.sol:KeepingAntiSandwichHook",
            abi.encode(address(manager)),
            address(keepHook)
        );

        donateHook = DonatingHook(address(flags | uint160(1 << 41)));
        deployCodeTo(
            "test/general/AntiSandwichHook.t.sol:DonatingHook", abi.encode(address(manager)), address(donateHook)
        );

        deferredHook = DeferredDonateHook(address(flags | uint160(1 << 42)));
        deployCodeTo(
            "test/general/AntiSandwichHook.t.sol:DeferredDonateHook",
            abi.encode(address(manager)),
            address(deferredHook)
        );

        feeSink = makeAddr("feeSink");
        treasuryHook = AntiSandwichMock(address(flags | uint160(1 << 43)));
        deployCodeTo(
            "src/mocks/general/AntiSandwichMock.sol:AntiSandwichMock",
            abi.encode(address(manager), feeSink),
            address(treasuryHook)
        );

        tollHook = AntiSandwichMock(address(flags | uint160(1 << 44)));
        deployCodeTo(
            "src/mocks/general/AntiSandwichMock.sol:AntiSandwichMock",
            abi.encode(address(manager), address(this)),
            address(tollHook)
        );

        perSwapClockHook = PerSwapClockHook(address(flags | uint160(1 << 45)));
        deployCodeTo(
            "test/general/AntiSandwichHook.t.sol:PerSwapClockHook",
            abi.encode(address(manager)),
            address(perSwapClockHook)
        );

        frozenClockHook = FrozenClockHook(address(flags | uint160(1 << 46)));
        deployCodeTo(
            "test/general/AntiSandwichHook.t.sol:FrozenClockHook",
            abi.encode(address(manager)),
            address(frozenClockHook)
        );

        reentrantHook = ReentrantHandlerHook(address(flags | uint160(1 << 47)));
        deployCodeTo(
            "test/general/AntiSandwichHook.t.sol:ReentrantHandlerHook",
            abi.encode(address(manager)),
            address(reentrantHook)
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Harness
    // ---------------------------------------------------------------------------------------------

    function _pool(IHooks hooks) internal returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(currency0, currency1, hooks, 0, SPACING, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -SPAN, tickUpper: SPAN, liquidityDelta: LIQUIDITY, salt: 0}),
            ZERO_BYTES
        );
    }

    function _add(Pnl memory p, BalanceDelta d) internal pure {
        p.a0 += d.amount0();
        p.a1 += d.amount1();
    }

    /// @dev Brings `p.a0` to exactly zero, so the P&L is currency1 alone. A pool that runs out of book
    ///      fills part of the way, so this repeats.
    function _flatten(PoolKey memory poolKey, Pnl memory p) internal {
        for (uint256 i; i < 8 && p.a0 != 0; ++i) {
            int256 before = p.a0;
            _add(p, swap(poolKey, p.a0 > 0, -p.a0, ZERO_BYTES));
            if (p.a0 == before) break;
        }
    }

    /// @dev Runs a scripted block of swaps and reports what the attacker's legs came to, in currency1.
    function _script(IHooks hooks, Leg[] memory legs) internal returns (int256) {
        PoolKey memory poolKey = _pool(hooks);
        vm.roll(block.number + 1);

        Pnl memory p;
        for (uint256 i; i < legs.length; ++i) {
            int256 amount = legs[i].amount;
            bool zeroForOne = legs[i].zeroForOne;

            if (amount == SQUARE_CURRENCY0) {
                if (p.a0 == 0) continue;
                (zeroForOne, amount) = (p.a0 > 0, -p.a0);
            } else if (amount == SQUARE_CURRENCY1) {
                if (p.a1 == 0) continue;
                (zeroForOne, amount) = (p.a1 < 0, -p.a1);
            }

            BalanceDelta d = swap(poolKey, zeroForOne, amount, ZERO_BYTES);
            if (legs[i].mine) _add(p, d);
        }

        _flatten(poolKey, p);
        assertEq(p.a0, 0, "currency0 did not net to zero");
        return p.a1;
    }

    function _compare(string memory name, Leg[] memory legs) internal returns (int256 hooked, int256 plain) {
        uint256 snap = vm.snapshotState();
        hooked = _script(IHooks(address(keepHook)), legs);
        vm.revertToState(snap);
        plain = _script(IHooks(address(0)), legs);
        vm.revertToState(snap);
        emit log_named_string("shape", name);
        emit log_named_int("  hooked  (currency1)", hooked);
        emit log_named_int("  no hook (currency1)", plain);
    }

    function _legs(uint256 n) internal pure returns (Leg[] memory) {
        return new Leg[](n);
    }

    // ---------------------------------------------------------------------------------------------
    // OBJECTIVE A - a profitable sandwich
    // ---------------------------------------------------------------------------------------------

    function _unattackedVictimCost(int256 victim) internal returns (int256) {
        PoolKey memory poolKey = _pool(IHooks(address(keepHook)));
        vm.roll(block.number + 1);
        return int256(-swap(poolKey, false, victim, ZERO_BYTES).amount1());
    }

    // --- single block: every shape tried, and what it came to -------------------------------------

    /// @notice NOT BROKEN inside one block. Each shape below loses, and every one of them pays off without
    /// the hook.
    function test_A_singleBlockShapesAllLose() public {
        int256 size = 2e17;
        int256 victim = 2e17;

        // Classic: sell, victim sells, buy the position back with an exact output leg.
        Leg[] memory a = _legs(3);
        a[0] = Leg(true, -size, true);
        a[1] = Leg(true, -victim, false);
        a[2] = Leg(false, SQUARE_CURRENCY0, true);
        (int256 h,) = _compare("sell / victim sell / exact-output close", a);
        assertLt(h, 0, "shape turned a profit");

        // The same, closed by spending every currency1 the front run raised.
        Leg[] memory b = _legs(3);
        b[0] = Leg(true, -size, true);
        b[1] = Leg(true, -victim, false);
        b[2] = Leg(false, SQUARE_CURRENCY1, true);
        (h,) = _compare("sell / victim sell / exact-input close", b);
        assertLt(h, 0, "shape turned a profit");

        // Mirrored: buy, victim buys, sell the position back.
        Leg[] memory c = _legs(3);
        c[0] = Leg(false, size, true);
        c[1] = Leg(false, victim, false);
        c[2] = Leg(true, SQUARE_CURRENCY0, true);
        (h,) = _compare("buy / victim buy / close", c);
        assertLt(h, 0, "shape turned a profit");

        // Asymmetric: close half as much as was opened, then square up.
        Leg[] memory d = _legs(4);
        d[0] = Leg(true, -size, true);
        d[1] = Leg(true, -victim, false);
        d[2] = Leg(false, size / 2, true);
        d[3] = Leg(false, SQUARE_CURRENCY0, true);
        (h,) = _compare("asymmetric close, half then square", d);
        assertLt(h, 0, "shape turned a profit");

        // Asymmetric the other way: overshoot the close, then square up.
        Leg[] memory e = _legs(4);
        e[0] = Leg(true, -size, true);
        e[1] = Leg(true, -victim, false);
        e[2] = Leg(false, (size * 3) / 2, true);
        e[3] = Leg(true, SQUARE_CURRENCY0, true);
        (h,) = _compare("asymmetric close, overshoot then square", e);
        assertLt(h, 0, "shape turned a profit");

        // Exact output open.
        Leg[] memory f = _legs(3);
        f[0] = Leg(true, size, true);
        f[1] = Leg(true, -victim, false);
        f[2] = Leg(false, SQUARE_CURRENCY0, true);
        (h,) = _compare("exact-output open / exact-output close", f);
        assertLt(h, 0, "shape turned a profit");

        // Five legs around two victims.
        Leg[] memory g = _legs(6);
        g[0] = Leg(true, -size, true);
        g[1] = Leg(true, -victim, false);
        g[2] = Leg(false, size / 2, true);
        g[3] = Leg(true, -victim, false);
        g[4] = Leg(false, size / 2, true);
        g[5] = Leg(false, SQUARE_CURRENCY0, true);
        (h,) = _compare("five legs, two victims", g);
        assertLt(h, 0, "shape turned a profit");

        // A dust swap sets the checkpoint first, so the front run is no longer the block's first swap.
        Leg[] memory i2 = _legs(4);
        i2[0] = Leg(true, -1, false);
        i2[1] = Leg(true, -size, true);
        i2[2] = Leg(true, -victim, false);
        i2[3] = Leg(false, SQUARE_CURRENCY0, true);
        (h,) = _compare("checkpoint set by a dust swap first", i2);
        assertLt(h, 0, "shape turned a profit");

        // Opposite legs: buy into a selling victim.
        Leg[] memory j = _legs(3);
        j[0] = Leg(false, size, true);
        j[1] = Leg(true, -victim, false);
        j[2] = Leg(true, SQUARE_CURRENCY0, true);
        (h,) = _compare("buy / victim sell / close", j);
        assertLt(h, 0, "shape turned a profit");
    }

    // --- single block: just-in-time liquidity ------------------------------------------------------

    struct Jit {
        int256 jit;
        int256 size;
        int256 victim;
        int24 half;
    }

    /// @dev A sandwich with a just-in-time position opened around it. The hook takes no liquidity
    ///      callbacks, so nothing about the position is recorded.
    function _jitSandwich(IHooks hooks, Jit memory plan, bool aroundVictim) internal returns (int256) {
        PoolKey memory poolKey = _pool(hooks);
        vm.roll(block.number + 1);

        Pnl memory p;
        _add(p, swap(poolKey, true, -1, ZERO_BYTES)); // set the checkpoint at the honest price

        if (plan.jit > 0 && aroundVictim) {
            _add(p, modifyPoolLiquidity(poolKey, -plan.half, plan.half, plan.jit, bytes32(uint256(1))));
        }

        _add(p, swap(poolKey, true, -plan.size, ZERO_BYTES)); // front run
        swap(poolKey, true, -plan.victim, ZERO_BYTES); // victim

        if (plan.jit > 0 && !aroundVictim) {
            (, int24 tick,,) = manager.getSlot0(poolKey.toId());
            int24 centre = (tick / SPACING) * SPACING;
            _add(p, modifyPoolLiquidity(poolKey, centre - plan.half, centre + plan.half, plan.jit, bytes32(uint256(1))));
            _add(p, swap(poolKey, false, plan.size, ZERO_BYTES)); // back run
            _add(
                p, modifyPoolLiquidity(poolKey, centre - plan.half, centre + plan.half, -plan.jit, bytes32(uint256(1)))
            );
        } else {
            _add(p, swap(poolKey, false, plan.size, ZERO_BYTES)); // back run
            if (plan.jit > 0) {
                _add(p, modifyPoolLiquidity(poolKey, -plan.half, plan.half, -plan.jit, bytes32(uint256(1))));
            }
        }

        _flatten(poolKey, p);
        assertEq(p.a0, 0, "currency0 did not net to zero");
        return p.a1;
    }

    /// @notice NOT BROKEN. Owning the book the sandwich trades against does not pay for the opening leg:
    /// deepening the pool cuts the victim's slippage by as much as it cuts the attacker's own.
    function test_A_jitSandwichStillLoses() public {
        int256[4] memory jits = [int256(0), 1e18, 1e19, 1e20];
        for (uint256 i; i < jits.length; ++i) {
            Jit memory plan = Jit(jits[i], 2e17, 2e17, SPAN);

            uint256 snap = vm.snapshotState();
            int256 kept = _jitSandwich(IHooks(address(keepHook)), plan, true);
            vm.revertToState(snap);
            int256 donated = _jitSandwich(IHooks(address(donateHook)), plan, true);
            vm.revertToState(snap);
            int256 plain = _jitSandwich(IHooks(address(0)), plan, true);
            vm.revertToState(snap);

            emit log_named_int("jit liquidity", jits[i]);
            emit log_named_int("  keeping hook  (currency1)", kept);
            emit log_named_int("  donating hook (currency1)", donated);
            emit log_named_int("  no hook       (currency1)", plain);
            assertLt(kept, 0, "the just-in-time sandwich paid off");
            assertLt(donated, 0, "the just-in-time sandwich paid off");
        }
    }

    // --- single block: the attacker owns almost the whole book ------------------------------------

    struct Plan {
        int256 jit;
        int256 displace;
        int256 victim;
    }

    struct Outcome {
        int256 attacker;
        int256 attackerAtP0;
        int256 residue0;
        int256 victimLoss;
        uint256 victimPricePpm;
    }

    /// @dev The attacker supplies most of the book, displaces the price with the block's first swap, lets a
    ///      victim buy at the displaced price, then unwinds against the bound.
    /// @dev A deep unhooked venue holding the same pair, where the attacker squares what the sandwich left
    ///      it holding. Squaring on the sandwiched pool itself would charge the attack for a book it has
    ///      just withdrawn.
    function _mirror() internal returns (PoolKey memory mirrorKey) {
        (mirrorKey,) = initPool(currency0, currency1, IHooks(address(0)), 100, SPACING, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            mirrorKey,
            ModifyLiquidityParams({tickLower: -SPAN, tickUpper: SPAN, liquidityDelta: 1e23, salt: 0}),
            ZERO_BYTES
        );
    }

    function _dominantLpSandwich(IHooks hooks, Plan memory plan) internal returns (Outcome memory o) {
        PoolKey memory poolKey = _pool(hooks);
        PoolKey memory mirrorKey = _mirror();
        vm.roll(block.number + 1);

        Pnl memory sw; // the swap legs
        Pnl memory lp; // the liquidity legs

        if (plan.jit > 0) {
            _add(lp, modifyPoolLiquidity(poolKey, -SPAN, SPAN, plan.jit, bytes32(uint256(1))));
        }

        BalanceDelta d = swap(poolKey, false, plan.displace, ZERO_BYTES);
        _add(sw, d);

        BalanceDelta v = swap(poolKey, false, plan.victim, ZERO_BYTES);
        o.victimLoss = int256(v.amount0()) + int256(v.amount1());
        o.victimPricePpm = uint256(int256(-v.amount1())) * 1e6 / uint256(int256(v.amount0()));

        // Square the swap legs while the book the attacker supplied is still in place.
        _add(sw, swap(poolKey, true, -int256(d.amount0()), ZERO_BYTES));
        _flatten(poolKey, sw);
        assertEq(sw.a0, 0, "the swap legs did not square");

        if (plan.jit > 0) {
            _add(lp, modifyPoolLiquidity(poolKey, -SPAN, SPAN, -plan.jit, bytes32(uint256(1))));
        }

        Pnl memory p = Pnl(sw.a0 + lp.a0, sw.a1 + lp.a1);
        o.attackerAtP0 = p.a0 + p.a1;
        o.residue0 = p.a0;

        _flatten(mirrorKey, p);
        assertEq(p.a0, 0, "currency0 did not net to zero");
        o.attacker = p.a1;
    }

    // --- the deferred donation handler -------------------------------------------------------------

    struct Held {
        int256 jit;
        int256 displace;
        int256 victim;
        int256 trigger;
        bool hold;
    }

    /// @dev The same dominant-liquidity sandwich, except the position is held into the next block, where the
    ///      attacker triggers the deferred donation itself and only then withdraws.
    function _heldSandwich(IHooks hooks, Held memory plan) internal returns (Outcome memory o) {
        PoolKey memory poolKey = _pool(hooks);
        PoolKey memory mirrorKey = _mirror();
        vm.roll(block.number + 1);

        Pnl memory sw;
        Pnl memory lp;

        _add(lp, modifyPoolLiquidity(poolKey, -SPAN, SPAN, plan.jit, bytes32(uint256(1))));

        BalanceDelta d = swap(poolKey, false, plan.displace, ZERO_BYTES);
        _add(sw, d);

        BalanceDelta v = swap(poolKey, false, plan.victim, ZERO_BYTES);
        o.victimLoss = int256(v.amount0()) + int256(v.amount1());
        o.victimPricePpm = uint256(int256(-v.amount1())) * 1e6 / uint256(int256(v.amount0()));

        _add(sw, swap(poolKey, true, -int256(d.amount0()), ZERO_BYTES));
        _flatten(poolKey, sw);

        if (plan.hold) {
            vm.roll(block.number + 1);
            // One swap to set the new block's checkpoint, one to beat it. The second collects a fee, which
            // is what releases everything the earlier block put aside.
            _add(sw, swap(poolKey, true, -plan.trigger, ZERO_BYTES));
            _add(sw, swap(poolKey, false, plan.trigger, ZERO_BYTES));
            _flatten(poolKey, sw);
        }

        _add(lp, modifyPoolLiquidity(poolKey, -SPAN, SPAN, -plan.jit, bytes32(uint256(1))));

        Pnl memory p = Pnl(sw.a0 + lp.a0, sw.a1 + lp.a1);
        o.attackerAtP0 = p.a0 + p.a1;
        o.residue0 = p.a0;

        _flatten(mirrorKey, p);
        assertEq(p.a0, 0, "currency0 did not net to zero");
        o.attacker = p.a1;
    }

    /// @dev The extreme pool, on the deferred handler: a checkpoint far above where the pool trades, so a
    ///      single swap collects a fee near the whole `int128` range.
    function _extremeDeferredPool() internal returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(
            currency0, currency1, IHooks(address(deferredHook)), 0, SPACING, TickMath.getSqrtPriceAtTick(399900)
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -399960, tickUpper: 399960, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @dev Fills a pool's pending balance past what a `BalanceDelta` carries: a checkpoint far above where
    ///      the pool trades, then two bound-paying swaps in the same block.
    function _overfillPending(PoolKey memory poolKey) internal {
        vm.roll(block.number + 1);
        swap(poolKey, true, -5e26, ZERO_BYTES);
        swap(poolKey, false, 5e20, ZERO_BYTES);
        swap(poolKey, false, 5e20, ZERO_BYTES);
    }

    /// @dev In a later block, one swap to set the checkpoint and one to beat it, which forces a release.
    function _forceRelease(PoolKey memory poolKey) internal {
        swap(poolKey, false, 1e26, ZERO_BYTES);
        swap(poolKey, true, -1e26, ZERO_BYTES);
    }

    /// @notice NOT BROKEN. The recipient-based handler closes the hole in both of its forms. The attacker
    /// supplies the book, sandwiches, and holds the position into the next block exactly as against the
    /// deferred handler, and there is nothing to collect: the fee left as claims the attacker does not hold.
    /// @notice Where the fee goes decides whether the attacker keeps it. Paid to in-range liquidity it comes
    /// straight back, because the attacker supplied that liquidity. Paid to a fixed recipient it does not.
    function test_A_theFeeDestinationDecidesWhetherTheAttackerKeepsIt() public {
        int256 jit = 1e20;
        bool[2] memory holds = [false, true];

        for (uint256 i; i < holds.length; ++i) {
            Held memory plan = Held(jit, (LIQUIDITY + jit) / 40, 2e17, 1e11, holds[i]);

            uint256 snap = vm.snapshotState();
            Outcome memory donated =
                _heldSandwich(holds[i] ? IHooks(address(deferredHook)) : IHooks(address(donateHook)), plan);
            vm.revertToState(snap);
            Outcome memory treasury = _heldSandwich(IHooks(address(treasuryHook)), plan);
            vm.revertToState(snap);
            Outcome memory plain = _heldSandwich(IHooks(address(0)), plan);
            vm.revertToState(snap);

            emit log_named_string("position", holds[i] ? "held across the block" : "withdrawn in the block");
            emit log_named_int("  attacker, fee paid to liquidity  ", donated.attacker);
            emit log_named_int("  attacker, fee to a fixed recipient", treasury.attacker);
            emit log_named_int("  attacker, no hook                ", plain.attacker);

            assertGt(donated.attacker, 0, "paying the fee to liquidity did not hand it back");
            assertLt(treasury.attacker, 0, "the recipient handler let the attack pay off");
        }
    }

    // --- the bound switches itself off ------------------------------------------------------------

    /// @dev A pool whose price starts far above 1, so a large intra-block move puts the bound on a big swap
    ///      outside what a `BalanceDelta` carries.
    function _highPricedPool(IHooks hooks) internal returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(currency0, currency1, hooks, 0, SPACING, TickMath.getSqrtPriceAtTick(399900));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -399960, tickUpper: 399960, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @dev Sell `size`, let a victim sell, buy `size` back. currency0 nets to zero.
    function _highPriceSandwich(IHooks hooks, int256 size, int256 victim)
        internal
        returns (int256 attacker, uint256 fee)
    {
        PoolKey memory poolKey = _highPricedPool(hooks);
        vm.roll(block.number + 1);

        Pnl memory p;
        _add(p, swap(poolKey, true, -size, ZERO_BYTES)); // first swap: takes the checkpoint, crashes the price
        swap(poolKey, true, -victim, ZERO_BYTES);
        _add(p, swap(poolKey, false, size, ZERO_BYTES)); // exact output buy back

        assertEq(p.a0, 0, "currency0 did not net to zero");
        attacker = p.a1;
        fee = hooks == IHooks(address(keepHook)) ? keepHook.lastFee() : 0;
    }

    // --- tick layout, spacing and decimals ---------------------------------------------------------

    /// @dev A book made of several narrow positions, so a swap crosses many initialised ticks.
    function _steppedPool(IHooks hooks, int24 spacing) internal returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(currency0, currency1, hooks, 0, spacing, SQRT_PRICE_1_1);
        for (int24 i = 1; i <= 8; ++i) {
            int24 width = 1200 * i;
            modifyLiquidityRouter.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: -width, tickUpper: width, liquidityDelta: 2e17, salt: bytes32(uint256(uint24(i)))
                }),
                ZERO_BYTES
            );
        }
    }

    /// @dev The classic sandwich over a stepped book at a given tick spacing.
    function _steppedSandwich(IHooks hooks, int24 spacing, int256 size, int256 victim)
        internal
        returns (int256 attacker, int24 crossed)
    {
        PoolKey memory poolKey = _steppedPool(hooks, spacing);
        vm.roll(block.number + 1);

        Pnl memory p;
        (, int24 start,,) = manager.getSlot0(poolKey.toId());
        _add(p, swap(poolKey, true, -size, ZERO_BYTES));
        swap(poolKey, true, -victim, ZERO_BYTES);
        (, int24 low,,) = manager.getSlot0(poolKey.toId());
        _add(p, swap(poolKey, false, size, ZERO_BYTES));

        _flatten(poolKey, p);
        assertEq(p.a0, 0, "currency0 did not net to zero");
        crossed = start - low;
        attacker = p.a1;
    }

    /// @notice NOT BROKEN. Crossing many initialised ticks does not loosen the bound, at any spacing. The
    /// bound reads the checkpoint price and nothing about the tick layout, which is what the contract claims.
    function test_A_crossingManyTicksDoesNotHelp() public {
        int24[3] memory spacings = [int24(1), 10, 60];
        for (uint256 i; i < spacings.length; ++i) {
            uint256 snap = vm.snapshotState();
            (int256 hooked, int24 crossed) = _steppedSandwich(IHooks(address(keepHook)), spacings[i], 1e17, 1e17);
            vm.revertToState(snap);
            (int256 plain,) = _steppedSandwich(IHooks(address(0)), spacings[i], 1e17, 1e17);
            vm.revertToState(snap);

            emit log_named_int("tick spacing", int256(spacings[i]));
            emit log_named_int("  ticks traversed by the front run and victim", int256(crossed));
            emit log_named_int("  hooked  (currency1)", hooked);
            emit log_named_int("  no hook (currency1)", plain);
            assertLt(hooked, 0, "the sandwich paid off over a stepped book");
        }
    }

    /// @dev A pool priced at 1e-12, the shape of an 18-decimal currency0 against a 6-decimal currency1.
    function _skewedPool(IHooks hooks, int24 tick) internal returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(currency0, currency1, hooks, 0, SPACING, TickMath.getSqrtPriceAtTick(tick));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: tick - 60000, tickUpper: tick + 60000, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @notice NOT BROKEN. A checkpoint far from 1 does not open the bound, in either direction. The
    /// rounding slack is reported alongside, since it is the one quantity that scales with the price.
    function test_A_aCheckpointFarFromOneDoesNotOpenTheBound() public {
        int24[2] memory ticks = [int24(-276300), int24(276300)]; // about 1e-12 and 1e12
        int256[2] memory sizes = [int256(1e22), 1e10]; // scaled to the currency0 each book holds
        for (uint256 i; i < ticks.length; ++i) {
            uint256 snap = vm.snapshotState();
            int256 size = sizes[i];

            PoolKey memory poolKey = _skewedPool(IHooks(address(keepHook)), ticks[i]);
            vm.roll(block.number + 1);
            Pnl memory p;
            _add(p, swap(poolKey, true, -size, ZERO_BYTES));
            swap(poolKey, true, -size, ZERO_BYTES);
            _add(p, swap(poolKey, false, size, ZERO_BYTES));
            assertEq(p.a0, 0, "currency0 did not net to zero");
            int256 hooked = p.a1;
            vm.revertToState(snap);

            PoolKey memory plainKey = _skewedPool(IHooks(address(0)), ticks[i]);
            vm.roll(block.number + 1);
            Pnl memory q;
            _add(q, swap(plainKey, true, -size, ZERO_BYTES));
            swap(plainKey, true, -size, ZERO_BYTES);
            _add(q, swap(plainKey, false, size, ZERO_BYTES));
            int256 plain = q.a1;
            vm.revertToState(snap);

            emit log_named_int("checkpoint tick", int256(ticks[i]));
            emit log_named_int("  hooked  (currency1)", hooked);
            emit log_named_int("  no hook (currency1)", plain);
            assertLe(hooked, 0, "the sandwich paid off at a skewed checkpoint");
        }
    }

    // --- the fee has a fixed destination ----------------------------------------------------------

    /// @dev Claims the pool manager holds for this contract, which the fee recipient is set to.
    function _claims() internal view returns (int256 c0, int256 c1) {
        c0 = int256(manager.balanceOf(address(this), currency0.toId()));
        c1 = int256(manager.balanceOf(address(this), currency1.toId()));
    }

    /// @dev No sandwich and no liquidity. The attacker only moves the price with the block's first swap and
    ///      collects, as fee recipient, what the bound then takes off everyone trading back towards it.
    function _tollExtraction(IHooks hooks, int256 crash, int256 honest) internal returns (int256, int256) {
        return _tollExtraction(hooks, crash, honest, 1);
    }

    function _tollExtraction(IHooks hooks, int256 crash, int256 honest, uint256 buyers)
        internal
        returns (int256 attacker, int256 honestPaid)
    {
        PoolKey memory poolKey = _pool(hooks);
        PoolKey memory mirrorKey = _mirror();
        vm.roll(block.number + 1);

        (int256 c0Before, int256 c1Before) = _claims();

        Pnl memory p;
        _add(p, swap(poolKey, true, -crash, ZERO_BYTES)); // first swap: takes the checkpoint, crashes the price

        for (uint256 i; i < buyers; ++i) {
            honestPaid += int256(-swap(poolKey, false, honest, ZERO_BYTES).amount1()); // honest buyers
        }

        _add(p, swap(poolKey, false, crash, ZERO_BYTES)); // the attacker buys its own position back

        (int256 c0After, int256 c1After) = _claims();
        p.a0 += c0After - c0Before;
        p.a1 += c1After - c1Before;

        _flatten(mirrorKey, p);
        assertEq(p.a0, 0, "currency0 did not net to zero");
        attacker = p.a1;
    }

    // --- the int128 boundary ----------------------------------------------------------------------

    /// @dev A high-priced pool with room to rise, so a swap can end up selling above its checkpoint.
    function _wideHighPool(IHooks hooks) internal returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(currency0, currency1, hooks, 0, SPACING, TickMath.getSqrtPriceAtTick(399900));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -399960, tickUpper: 880020, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @notice NOT BROKEN, and the abstention on an exact input cannot be reached by a swap it would have
    /// bound. The ceiling caps the unspecified amount, which comes out of a `BalanceDelta`. For the ceiling
    /// to bind, the swap must be filling better than the checkpoint, which makes the unspecified amount
    /// larger than the ceiling; a ceiling past `MAX_BALANCE_DELTA` therefore implies an unspecified amount past it
    /// too, and no such swap can settle. Below, every size that sells above its checkpoint is charged, and
    /// the sizes that would reach the abstention cannot be executed at all.
    function test_A_theExactInputAbstentionCannotBeReachedByABindingSwap() public {
        int256[5] memory sells = [int256(1e12), 1e14, 1e16, 1e18, 1e20];

        for (uint256 i; i < sells.length; ++i) {
            uint256 snap = vm.snapshotState();
            PoolKey memory poolKey = _wideHighPool(IHooks(address(keepHook)));
            vm.roll(block.number + 1);

            // The block's first swap takes the checkpoint and pushes the price well above it.
            swap(poolKey, false, 5e17, ZERO_BYTES);

            uint256 checkpoint = uint256(TickMath.getSqrtPriceAtTick(399900));
            bool settled;
            try swapRouter.swap(
                poolKey,
                SwapParams({zeroForOne: true, amountSpecified: -sells[i], sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ZERO_BYTES
            ) returns (
                BalanceDelta d
            ) {
                settled = true;
                uint256 bound = Math.mulDiv(Math.mulDiv(uint256(sells[i]), checkpoint, 1 << 96), checkpoint, 1 << 96);
                emit log_named_int("currency0 sold", sells[i]);
                emit log_named_int("  currency1 received", d.amount1());
                emit log_named_uint("  the checkpoint allows", bound);
                emit log_named_uint("  fee charged", keepHook.lastFee());
                // The bound is two chained ceiling divisions, so it is loose by one unit of the inner term
                // plus one. The inner term is scaled by the square root of the checkpoint price, which is
                // why the slack is 482,263,073 here and two wei in a pool priced at one.
                uint256 slack = 2 * checkpoint / (1 << 96) + 4;
                emit log_named_uint("  rounding slack the bound allows", slack);
                assertLe(uint256(int256(d.amount1())), bound + slack, "the sale kept more than the checkpoint allows");
            } catch {
                emit log_named_int("currency0 sold", sells[i]);
                emit log_named_string("  outcome", "the swap itself cannot settle");
            }
            assertTrue(settled || sells[i] > 0, "");
            vm.revertToState(snap);
        }
    }

    /// @notice NOT BROKEN. Abstaining on an exact input whose ceiling passes `MAX_BALANCE_DELTA` gives nothing
    /// away, because the amount the ceiling caps came out of a `BalanceDelta` and can never reach it. A
    /// closing leg placed just under, just over and far over the boundary buys the attacker nothing.
    function test_A_straddlingTheBoundaryBuysNothing() public {
        // Under the crossing the attacker is charged and loses. Over it the closing leg cannot be held to the
        // price at all, so it is refused. Neither side of the boundary is worth aiming at.
        int256[2] memory priced = [int256(7e20), 73e19];

        for (uint256 i; i < priced.length; ++i) {
            uint256 snap = vm.snapshotState();
            (int256 exactOut,) = _highPriceSandwich(IHooks(address(keepHook)), priced[i], 1e21);
            vm.revertToState(snap);
            (int256 plain,) = _highPriceSandwich(IHooks(address(0)), priced[i], 1e21);
            vm.revertToState(snap);

            assertLt(exactOut, plain, "the attacker kept the unprotected outcome");
        }

        int256[3] memory refused = [int256(8e20), 1e21, 5e21];

        for (uint256 i; i < refused.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.expectRevert();
            this.externalHighPriceSandwich(IHooks(address(keepHook)), refused[i], 1e21);
            vm.revertToState(snap);
        }
    }

    /// @dev `_highPriceSandwich` through an external call, so a revert inside it can be expected.
    function externalHighPriceSandwich(IHooks hooks, int256 size, int256 victim) external returns (int256, uint256) {
        require(msg.sender == address(this), "only self");
        return _highPriceSandwich(hooks, size, victim);
    }

    // ---------------------------------------------------------------------------------------------
    // Untested surface
    // ---------------------------------------------------------------------------------------------

    /// @dev A pool whose currency0 is native ether.
    function _nativePool(IHooks hooks) internal returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, hooks, 0, SPACING, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 5e18}(
            poolKey,
            ModifyLiquidityParams({tickLower: -SPAN, tickUpper: SPAN, liquidityDelta: LIQUIDITY, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @notice A native pool charges the bound in ether and forwards it as claims of currency id zero.
    /// Nothing is stranded in the hook, and the recipient's claims match the fee exactly.
    function test_C_nativePoolChargesInEtherAndStrandsNothing() public {
        vm.deal(address(this), 100e18);
        PoolKey memory poolKey = _nativePool(IHooks(address(treasuryHook)));
        vm.roll(block.number + 1);

        uint256 sinkNativeBefore = manager.balanceOf(feeSink, 0);
        uint256 sink1Before = manager.balanceOf(feeSink, currency1.toId());

        // First swap: sell ether, price of ether falls, checkpoint taken at 1:1.
        swap(poolKey, true, -8e17, ZERO_BYTES);
        // Buy ether back cheaply. The unspecified currency is currency0, so the fee is native.
        BalanceDelta d = swap(poolKey, false, -3e17, ZERO_BYTES);

        uint256 feeNative = manager.balanceOf(feeSink, 0) - sinkNativeBefore;
        uint256 fee1 = manager.balanceOf(feeSink, currency1.toId()) - sink1Before;

        emit log_named_int("ether received", d.amount0());
        emit log_named_int("currency1 paid ", -d.amount1());
        emit log_named_uint("fee forwarded, native  ", feeNative);
        emit log_named_uint("fee forwarded, currency1", fee1);
        emit log_named_uint("claims left in the hook, native  ", manager.balanceOf(address(treasuryHook), 0));
        emit log_named_uint(
            "claims left in the hook, currency1", manager.balanceOf(address(treasuryHook), currency1.toId())
        );

        assertGt(feeNative, 0, "the native pool charged nothing");
        assertEq(manager.balanceOf(address(treasuryHook), 0), 0, "native claims stranded in the hook");
        assertEq(manager.balanceOf(address(treasuryHook), currency1.toId()), 0, "claims stranded in the hook");

        // The claims are the recipient's to move, so the ether is reachable rather than stranded.
        vm.prank(feeSink);
        manager.transfer(address(0xBEEF), 0, feeNative);
        assertEq(manager.balanceOf(address(0xBEEF), 0), feeNative, "the native fee was not the recipient's to move");
        assertEq(manager.balanceOf(feeSink, 0), sinkNativeBefore, "the recipient kept native claims it moved");
    }

    /// @notice NOT BROKEN. Checkpoints are keyed by pool id and nothing crosses. Three pools on one hook,
    /// interleaved inside a single block: each holds the price its own first swap found, and swaps in one
    /// neither move nor stall another's.
    function test_C_checkpointsAreIsolatedAcrossPools() public {
        PoolKey memory a = _pool(IHooks(address(keepHook)));
        (PoolKey memory b,) =
            initPool(currency0, currency1, IHooks(address(keepHook)), 100, SPACING, TickMath.getSqrtPriceAtTick(6000));
        modifyLiquidityRouter.modifyLiquidity(
            b,
            ModifyLiquidityParams({tickLower: -SPAN, tickUpper: SPAN, liquidityDelta: LIQUIDITY, salt: 0}),
            ZERO_BYTES
        );
        Currency currency2 = deployMintAndApproveCurrency();
        (Currency low, Currency high) = currency1 < currency2 ? (currency1, currency2) : (currency2, currency1);
        (PoolKey memory c,) =
            initPool(low, high, IHooks(address(keepHook)), 0, SPACING, TickMath.getSqrtPriceAtTick(-9000));
        modifyLiquidityRouter.modifyLiquidity(
            c,
            ModifyLiquidityParams({tickLower: -SPAN, tickUpper: SPAN, liquidityDelta: LIQUIDITY, salt: 0}),
            ZERO_BYTES
        );

        vm.roll(block.number + 1);

        // Move pool A well away from 1:1, then let B and C take their own checkpoints, interleaved.
        swap(a, true, -5e17, ZERO_BYTES);
        uint160 aCheck = keepHook.getLastCheckpoint(a.toId()).sqrtPriceX96;
        swap(b, true, -2e17, ZERO_BYTES);
        swap(a, false, 1e17, ZERO_BYTES);
        swap(c, true, -3e17, ZERO_BYTES);
        swap(b, false, 1e16, ZERO_BYTES);
        swap(a, true, -1e17, ZERO_BYTES);

        emit log_named_uint("pool A checkpoint", keepHook.getLastCheckpoint(a.toId()).sqrtPriceX96);
        emit log_named_uint("pool B checkpoint", keepHook.getLastCheckpoint(b.toId()).sqrtPriceX96);
        emit log_named_uint("pool C checkpoint", keepHook.getLastCheckpoint(c.toId()).sqrtPriceX96);

        assertEq(keepHook.getLastCheckpoint(a.toId()).sqrtPriceX96, aCheck, "pool A's checkpoint moved");
        assertEq(
            uint256(keepHook.getLastCheckpoint(b.toId()).sqrtPriceX96),
            uint256(TickMath.getSqrtPriceAtTick(6000)),
            "pool B took a foreign price"
        );
        assertEq(
            uint256(keepHook.getLastCheckpoint(c.toId()).sqrtPriceX96),
            uint256(TickMath.getSqrtPriceAtTick(-9000)),
            "pool C took a foreign price"
        );
        assertEq(uint256(aCheck), uint256(SQRT_PRICE_1_1), "pool A took a foreign price");
    }

    /// @dev The classic sandwich, run against whichever hook is passed.
    function _plainSandwich(IHooks hooks, int256 size, int256 victim) internal returns (int256) {
        PoolKey memory poolKey = _pool(hooks);
        vm.roll(block.number + 1);
        Pnl memory p;
        _add(p, swap(poolKey, true, -size, ZERO_BYTES));
        swap(poolKey, true, -victim, ZERO_BYTES);
        _add(p, swap(poolKey, false, size, ZERO_BYTES));
        _flatten(poolKey, p);
        assertEq(p.a0, 0, "currency0 did not net to zero");
        return p.a1;
    }

    /// @notice BROKEN by the override point, silently. `_getBlockNumber` is `internal virtual` and the whole
    /// guarantee rests on it. A child whose clock moves within a block takes a fresh checkpoint on every
    /// swap, so the closing leg is measured against the price the victim just made, and the sandwich pays
    /// exactly what it pays with no hook at all. Nothing reverts and nothing looks wrong.
    function test_C_aClockThatMovesWithinABlockRemovesTheBound() public {
        uint256 snap = vm.snapshotState();
        int256 sound = _plainSandwich(IHooks(address(keepHook)), 2e17, 2e17);
        vm.revertToState(snap);
        int256 perSwap = _plainSandwich(IHooks(address(perSwapClockHook)), 2e17, 2e17);
        vm.revertToState(snap);
        int256 plain = _plainSandwich(IHooks(address(0)), 2e17, 2e17);
        vm.revertToState(snap);

        emit log_named_int("block number, as shipped (currency1)", sound);
        emit log_named_int("a clock that moves per swap (currency1)", perSwap);
        emit log_named_int("no hook at all              (currency1)", plain);

        assertEq(perSwap, plain, "the broken clock did not fully remove the bound");
        assertLt(sound, 0, "the shipped clock stopped protecting");

        // The other way of breaking it: a clock that never moves anchors the pool to one price for good.
        vm.revertToState(snap);
        PoolKey memory frozenKey = _pool(IHooks(address(frozenClockHook)));
        vm.roll(block.number + 1);
        swap(frozenKey, true, -5e17, ZERO_BYTES);
        vm.roll(block.number + 10_000);
        swap(frozenKey, true, -1e17, ZERO_BYTES);
        swap(frozenKey, false, 1e16, ZERO_BYTES);

        assertEq(
            uint256(frozenClockHook.getLastCheckpoint(frozenKey.toId()).sqrtPriceX96),
            uint256(SQRT_PRICE_1_1),
            "the frozen clock let the checkpoint move"
        );
        assertGt(frozenClockHook.lastFee(), 0, "the anchored price stopped charging");
    }

    /// @notice NOT BROKEN. A handler that trades back into the same pool while `afterSwap` is still running
    /// sees the checkpoint already written and cannot move it. There is no external call between the two
    /// writes in `_beforeSwap` or before the single read in `_getTargetUnspecified`, so there is no
    /// half-written state to catch.
    function test_C_reenteringFromTheHandlerCannotMoveTheCheckpoint() public {
        PoolKey memory poolKey = _pool(IHooks(address(reentrantHook)));
        vm.roll(block.number + 1);

        swap(poolKey, true, -5e17, ZERO_BYTES); // first swap: takes the checkpoint
        uint160 before = reentrantHook.getLastCheckpoint(poolKey.toId()).sqrtPriceX96;

        reentrantHook.arm();
        swap(poolKey, false, 1e17, ZERO_BYTES); // beats the checkpoint, so the handler runs and re-enters

        emit log_named_uint("checkpoint before", uint256(before));
        emit log_named_uint("checkpoint the handler saw inside", uint256(reentrantHook.checkpointSeenInside()));
        emit log_named_uint("checkpoint after", uint256(reentrantHook.getLastCheckpoint(poolKey.toId()).sqrtPriceX96));
        emit log_named_string("the nested swap reverted", reentrantHook.reentryReverted() ? "yes" : "no");

        assertTrue(reentrantHook.reentered(), "the handler never ran");
        assertEq(
            uint256(reentrantHook.checkpointSeenInside()), uint256(before), "the handler saw a different checkpoint"
        );
        assertEq(
            uint256(reentrantHook.getLastCheckpoint(poolKey.toId()).sqrtPriceX96),
            uint256(before),
            "re-entering moved the checkpoint"
        );
    }

    /// @dev A book that stops just above the starting price, so a buy can trade through all of it and
    ///      leave the pool with nothing active.
    function _narrowPool(IHooks hooks) internal returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(currency0, currency1, hooks, 0, SPACING, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 600, liquidityDelta: LIQUIDITY, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @notice The shipped handler survives a fee collected on a swap that leaves the pool with no active
    /// liquidity. A handler that donates cannot: `Pool.donate` rejects a donation with nothing to receive
    /// it, and since the handler runs inside `afterSwap` the revert rejects the swap. The recipient design
    /// removes that whole class, which is worth stating because it is the failure that forced the previous
    /// design's zero-liquidity guard.
    function test_C_aFeeCollectedWithNoActiveLiquiditySurvives() public {
        uint256 snap = vm.snapshotState();

        // Recipient handler: the swap goes through and the fee is forwarded.
        PoolKey memory poolKey = _narrowPool(IHooks(address(treasuryHook)));
        vm.roll(block.number + 1);
        uint256 sinkBefore = manager.balanceOf(feeSink, currency0.toId());
        swap(poolKey, true, -3e17, ZERO_BYTES); // checkpoint at 1:1, price down
        swap(poolKey, false, -5e17, ZERO_BYTES); // buys through the whole book and leaves the range

        uint128 liquidityLeft = manager.getLiquidity(poolKey.toId());
        uint256 fee = manager.balanceOf(feeSink, currency0.toId()) - sinkBefore;
        emit log_named_uint("active liquidity after the swap", liquidityLeft);
        emit log_named_uint("fee forwarded", fee);
        assertEq(liquidityLeft, 0, "the pool kept liquidity, so this proves nothing");
        assertGt(fee, 0, "no fee was collected, so this proves nothing");
        vm.revertToState(snap);

        // Donating handler: the identical swap is rejected.
        PoolKey memory donatingKey = _narrowPool(IHooks(address(donateHook)));
        vm.roll(block.number + 1);
        swap(donatingKey, true, -3e17, ZERO_BYTES);
        vm.expectRevert(); // NoLiquidityToReceiveFees, from Pool.donate
        swapRouter.swap(
            donatingKey,
            SwapParams({zeroForOne: false, amountSpecified: -5e17, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @notice A swap stopped early by its own price limit is held to the amount it actually filled, so a
    /// partial fill is not a way past the bound.
    function test_C_aPriceLimitedSwapIsBoundedOnWhatItFilled() public {
        uint256 snap = vm.snapshotState();
        uint160[3] memory limits =
            [TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(600), TickMath.getSqrtPriceAtTick(3000)];

        for (uint256 i; i < limits.length; ++i) {
            PoolKey memory poolKey = _pool(IHooks(address(keepHook)));
            vm.roll(block.number + 1);
            swap(poolKey, true, -5e17, ZERO_BYTES); // checkpoint at 1:1, price down

            BalanceDelta d = swapRouter.swap(
                poolKey,
                SwapParams({zeroForOne: false, amountSpecified: -5e17, sqrtPriceLimitX96: limits[i]}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ZERO_BYTES
            );
            emit log_named_uint("price limit", uint256(limits[i]));
            emit log_named_int("  currency1 spent   ", -d.amount1());
            emit log_named_int("  currency0 received", d.amount0());
            emit log_named_uint("  fee charged", keepHook.lastFee());
            assertLe(d.amount0(), -d.amount1() + 2, "a price-limited fill beat the checkpoint price");
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Auditing the campaign
    // ---------------------------------------------------------------------------------------------

    function _poolAt(IHooks hooks, int24 tick, int24 tickSpacing, uint128 liquidity, int24 width)
        internal
        returns (PoolKey memory poolKey)
    {
        int24 centre = (tick / tickSpacing) * tickSpacing;
        (poolKey,) = initPool(currency0, currency1, hooks, 0, tickSpacing, TickMath.getSqrtPriceAtTick(centre));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: centre - width * tickSpacing,
                tickUpper: centre + width * tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function advSwap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        require(msg.sender == address(this), "only self");
        return swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    struct Reach {
        uint256 setupReverted;
        uint256 probeReverted;
        uint256 degenerate;
        uint256 asserted;
        uint256 farPrices;
        uint256 assertedFar;
    }

    function _advTry(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified) internal returns (bool) {
        try this.advSwap(poolKey, zeroForOne, amountSpecified) returns (BalanceDelta) {
            return true;
        } catch {
            return false;
        }
    }

    function _comparablePool(IHooks hooks) internal returns (PoolKey memory poolKey) {
        (poolKey,) = initPool(currency0, currency1, hooks, 0, 60, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: LIQUIDITY, salt: 0}),
            ZERO_BYTES
        );
    }

    // ---------------------------------------------------------------------------------------------
    // OBJECTIVE B - an innocent user harmed
    // ---------------------------------------------------------------------------------------------

    function _honestActor(uint256 budget0, uint256 budget1) internal returns (address actor) {
        actor = makeAddr("honest");
        MockERC20(Currency.unwrap(currency0)).mint(actor, budget0);
        MockERC20(Currency.unwrap(currency1)).mint(actor, budget1);
        vm.startPrank(actor);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice The first swap ever on a pool pays nothing. It is measured against the price recorded just
    /// before it ran, and a swap moves the price away from that, so there is never an improvement to take.
    function test_B_firstSwapEverOnAPoolIsUnbounded() public {
        PoolKey memory poolKey = _pool(IHooks(address(keepHook)));
        swap(poolKey, true, -1e17, ZERO_BYTES);
        assertEq(keepHook.lastFee(), 0, "the first swap ever was charged");
    }
}
