// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "src/base/BaseHook.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {AntiSandwichHook} from "src/general/AntiSandwichHook.sol";
import {AntiSandwichMock} from "src/mocks/general/AntiSandwichMock.sol";
import {BaseHandler} from "../BaseHandler.sol";

/**
 * @dev Handler for `AntiSandwichHook` invariant campaigns.
 *
 * Fuzzable surface:
 * - `swap`
 * - `sandwich`
 * - `sandwichOverOwnBook`
 * - `addLiquidity`
 * - `removeLiquidity`
 * - `donate`
 * - `nextBlock`
 *
 * Every swap the handler makes is checked against the beginning-of-block price as it returns, so the bound
 * is asserted on the whole swap surface rather than sampled. Every action runs under {stateTransition},
 * which asserts the checkpoint moves only when a new block claims it.
 */
contract AntiSandwichHookHandler is BaseHandler {
    using StateLibrary for IPoolManager;

    /// @dev `IHookEvents.HookFee(bytes32,address,uint128,uint128)`.
    bytes32 private constant HOOK_FEE_TOPIC = keccak256("HookFee(bytes32,address,uint128,uint128)");

    /// @dev `CustomRevert.WrappedError(address,bytes4,bytes,bytes)`.
    bytes4 private constant WRAPPED_ERROR_SELECTOR = 0x90bfb865;

    AntiSandwichMock public hook;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolDonateTest public donateRouter;

    /// @dev Outermost tick a swap may reach. Keeps the price inside the funded range.
    int24 public immutable TICK_WINDOW_EDGE;

    /// @dev Fuzzer bounds for swap `amount`.
    uint256 public immutable AMOUNT_MIN_BOUND;
    uint256 public immutable AMOUNT_MAX_BOUND;

    /// @dev Fuzzer bounds for position `liquidity`.
    uint256 public immutable LIQUIDITY_MIN_BOUND;
    uint256 public immutable LIQUIDITY_MAX_BOUND;

    struct Bounds {
        int24 tickWindowEdge;
        uint256 amountMinBound;
        uint256 amountMaxBound;
        uint256 liquidityMinBound;
        uint256 liquidityMaxBound;
    }

    struct Pos {
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        uint128 liquidity;
    }

    Pos[] internal ghost_positions;

    /// @dev Swaps whose fill was compared against the beginning-of-block price.
    uint256 public ghost_boundChecks;

    /// @dev Swaps that paid a fee, and the totals in each currency.
    uint256 public ghost_feeCharges;
    uint256 public ghost_totalFee0;
    uint256 public ghost_totalFee1;

    /// @dev Swaps that were the first of their block, and those that paid a fee despite being first.
    uint256 public ghost_firstSwapsOfBlock;
    uint256 public ghost_firstSwapFees;

    /// @dev Blocks that saw more than one swap.
    uint256 public ghost_multiSwapBlocks;
    uint256 internal _swapsThisBlock;
    uint256 internal _lastSwapBlock;

    /// @dev The best result any attempted sandwich reached, valued in currency1 at the block's own price.
    /// Positive means an attacker ended a block ahead.
    int256 public ghost_bestSandwichPnl;
    int256 public ghost_bestPlainSandwichPnl;
    uint256 public ghost_sandwichesMeasured;
    uint256 public ghost_ownedBookSandwiches;

    /// @dev The most an attacker owning the book gained by taking the swap legs itself rather than leaving
    /// someone else, with the position and the flow held identical.
    int256 public ghost_bestOwnedBookEdge;

    /// @dev Swaps the pool accepted whose `afterSwap` the hook rejected.
    uint256 public ghost_hookRejections;
    bytes public ghost_lastRejection;

    /// @dev Gas the costliest first swap of a block consumed.
    uint256 public ghost_maxFirstSwapGas;

    constructor(
        AntiSandwichMock hook_,
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        PoolModifyLiquidityTest modifyLiquidityRouter_,
        PoolDonateTest donateRouter_,
        PoolKey memory key_,
        address[] memory actors_,
        int24[] memory ticks_,
        Bounds memory bounds
    ) {
        hook = hook_;
        manager = manager_;
        swapRouter = swapRouter_;
        modifyLiquidityRouter = modifyLiquidityRouter_;
        donateRouter = donateRouter_;
        key = key_;
        poolId = key_.toId();

        TICK_WINDOW_EDGE = bounds.tickWindowEdge;
        AMOUNT_MIN_BOUND = bounds.amountMinBound;
        AMOUNT_MAX_BOUND = bounds.amountMaxBound;
        LIQUIDITY_MIN_BOUND = bounds.liquidityMinBound;
        LIQUIDITY_MAX_BOUND = bounds.liquidityMaxBound;

        _createActors(actors_);
        _createTicks(ticks_);
    }

    /// @dev Asserts the checkpoint moved only because a new block claimed it.
    modifier stateTransition() {
        (uint160 priceBefore, uint48 blockBefore) = _checkpoint();
        _;
        (uint160 priceAfter, uint48 blockAfter) = _checkpoint();

        if (priceAfter != priceBefore || blockAfter != blockBefore) {
            assertEq(uint256(blockAfter), block.number, "INV-02: the checkpoint moved without claiming the block");
            assertTrue(blockBefore != uint48(block.number), "INV-02: the checkpoint was rewritten inside its block");
        }
    }

    // --------------- Actions --------------- //

    function swap(uint256 actorSeed, uint256 amountSeed, bool zeroForOne, bool exactInput)
        external
        recordCall("swap")
        stateTransition
    {
        uint256 amount = bound(amountSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND);
        _checkedSwap(_actorFromSeed(actorSeed), zeroForOne, exactInput ? -int256(amount) : int256(amount));
    }

    /// @dev A front run, a victim and a back run in one block, closing the same size the attack opened.
    function sandwich(uint256 sizeSeed, uint256 victimSeed, bool openWithBuy)
        external
        recordCall("sandwich")
        stateTransition
    {
        uint256 size = bound(sizeSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND / 4);
        uint256 victim = bound(victimSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND / 4);

        address attacker = _actorFromSeed(0);
        uint160 price = _valuationPrice();
        int256 opening = _measureValue(attacker, price);

        if (!_runSandwichLegs(attacker, _actorFromSeed(1), size, victim, openWithBuy)) return;

        int256 pnl = _recordSandwich(attacker, opening, price);
        if (pnl > ghost_bestPlainSandwichPnl) ghost_bestPlainSandwichPnl = pnl;
        ++ghost_sandwichesMeasured;
    }

    /// @dev The same attack with the attacker also providing the liquidity the victim trades through, added
    /// and removed inside the block. The hook takes no liquidity callbacks, so nothing records this.
    struct OwnBookPlan {
        uint256 size;
        uint256 victim;
        uint256 liquidity;
        int24 lower;
        int24 upper;
        bytes32 salt;
        bool openWithBuy;
    }

    /**
     * @dev A sandwich whose attacker also supplies the liquidity it trades through, added and removed inside
     * the block. The hook takes no liquidity callbacks, so nothing records the position.
     *
     * The same plan is run twice under state snapshots. In the first arm the attacker takes both swap legs;
     * in the second an unrelated actor takes the identical legs and the attacker only provides. The
     * difference is what the attacker gained by swapping rather than by providing, which is the part a bound
     * on swaps is answerable for.
     */
    function sandwichOverOwnBook(uint256 sizeSeed, uint256 victimSeed, uint256 liquiditySeed, bool openWithBuy)
        external
        recordCall("sandwichOverOwnBook")
        stateTransition
    {
        OwnBookPlan memory plan;
        plan.size = bound(sizeSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND / 4);
        plan.victim = bound(victimSeed, AMOUNT_MIN_BOUND, AMOUNT_MAX_BOUND / 4);
        plan.liquidity = bound(liquiditySeed, LIQUIDITY_MIN_BOUND, LIQUIDITY_MAX_BOUND);
        plan.lower = _floor(_storedTick()) - 4 * key.tickSpacing;
        plan.upper = plan.lower + 8 * key.tickSpacing;
        plan.salt = keccak256(abi.encode("ownBook", liquiditySeed, block.number));
        plan.openWithBuy = openWithBuy;

        uint256 snap = vm.snapshotState();
        (int256 attacking, bool attackingOk) = _runOverOwnBook(plan, _actorFromSeed(0));
        vm.revertToState(snap);

        snap = vm.snapshotState();
        (int256 providing, bool providingOk) = _runOverOwnBook(plan, _actorFromSeed(2));
        vm.revertToState(snap);

        if (!attackingOk || !providingOk) return;

        // Leave the attacking arm standing, so the sequence carries its state forward.
        _runOverOwnBook(plan, _actorFromSeed(0));

        int256 edge = attacking - providing;
        if (edge > ghost_bestOwnedBookEdge) ghost_bestOwnedBookEdge = edge;
        ++ghost_ownedBookSandwiches;
    }

    /// @dev Runs `plan` with actor 0 providing the liquidity and `opener` taking both swap legs. Returns
    /// what the provider gained, valued at the price the block is measured against.
    function _runOverOwnBook(OwnBookPlan memory plan, address opener) private returns (int256 pnl, bool ok) {
        address provider = _actorFromSeed(0);
        uint160 price = _valuationPrice();
        int256 opening = _measureValue(provider, price);

        if (!_modify(provider, plan.lower, plan.upper, int256(plan.liquidity), plan.salt)) return (0, false);
        bool ran = _runSandwichLegs(opener, _actorFromSeed(1), plan.size, plan.victim, plan.openWithBuy);
        if (!_modify(provider, plan.lower, plan.upper, -int256(plan.liquidity), plan.salt)) return (0, false);
        if (!ran) return (0, false);

        return (_measureValue(provider, price) - opening, true);
    }

    function addLiquidity(uint256 actorSeed, uint256 tickSeed, uint256 liquiditySeed)
        external
        recordCall("addLiquidity")
        stateTransition
    {
        int24 lower = _floor(_tickFromSeed(tickSeed));
        int24 upper = lower + key.tickSpacing * int24(int256(bound(liquiditySeed, 1, 8)));
        uint256 liquidity = bound(liquiditySeed, LIQUIDITY_MIN_BOUND, LIQUIDITY_MAX_BOUND);
        bytes32 salt = keccak256(abi.encode(ghost_positions.length, actorSeed));

        address actor = _actorFromSeed(actorSeed);
        if (!_modify(actor, lower, upper, int256(liquidity), salt)) return;

        ghost_positions.push(Pos({tickLower: lower, tickUpper: upper, salt: salt, liquidity: uint128(liquidity)}));
    }

    function removeLiquidity(uint256 actorSeed, uint256 positionSeed)
        external
        recordCall("removeLiquidity")
        stateTransition
    {
        if (ghost_positions.length == 0) return;

        uint256 index = positionSeed % ghost_positions.length;
        Pos memory position = ghost_positions[index];
        if (position.liquidity == 0) return;

        address actor = _actorFromSeed(actorSeed);
        if (!_modify(
                actor, position.tickLower, position.tickUpper, -int256(uint256(position.liquidity)), position.salt
            )) {
            return;
        }

        ghost_positions[index].liquidity = 0;
    }

    function donate(uint256 amountSeed) external recordCall("donate") stateTransition {
        uint256 amount = bound(amountSeed, 1, AMOUNT_MAX_BOUND / 100);
        if (manager.getLiquidity(poolId) == 0) return;

        vm.prank(_actorFromSeed(amountSeed));
        try donateRouter.donate(key, amount, amount, "") {} catch {}
    }

    function nextBlock(uint256 seed) external recordCall("nextBlock") stateTransition {
        vm.roll(block.number + bound(seed, 1, 3));
    }

    // --------------- Views --------------- //

    function checkpointPrice() public view returns (uint160 price) {
        (price,) = _checkpoint();
    }

    function checkpointBlock() public view returns (uint48 blockNumber) {
        (, blockNumber) = _checkpoint();
    }

    function positionCount() public view returns (uint256) {
        return ghost_positions.length;
    }

    // --------------- Internals --------------- //

    function _checkpoint() private view returns (uint160 price, uint48 blockNumber) {
        AntiSandwichHook.Checkpoint memory checkpoint = hook.getLastCheckpoint(poolId);
        return (checkpoint.sqrtPriceX96, checkpoint.blockNumber);
    }

    /// @dev Runs one swap as `actor` and asserts what it filled against the beginning-of-block price.
    /// Named apart from {BaseHandler-_swap}, which takes no actor and makes no assertion.
    function _checkedSwap(address actor, bool zeroForOne, int256 amountSpecified) private returns (bool filled) {
        (uint160 priceBefore, uint48 blockBefore) = _checkpoint();
        bool isFirstOfBlock = blockBefore != uint48(block.number);

        uint160 limit =
            zeroForOne ? TickMath.getSqrtPriceAtTick(-TICK_WINDOW_EDGE) : TickMath.getSqrtPriceAtTick(TICK_WINDOW_EDGE);

        vm.recordLogs();
        uint256 gasBefore = gasleft();
        vm.prank(actor);
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta delta
        ) {
            uint256 used = gasBefore - gasleft();
            if (isFirstOfBlock) {
                ++ghost_firstSwapsOfBlock;
                if (used > ghost_maxFirstSwapGas) ghost_maxFirstSwapGas = used;
            }

            uint256 fee = _feeFromLogs();
            if (fee > 0) {
                ++ghost_feeCharges;
                if (isFirstOfBlock) ++ghost_firstSwapFees;
            }

            _countSwap();
            _assertBound(delta);
            return true;
        } catch (bytes memory reason) {
            // A revert the pool itself would have produced is not a hook rejection. The hook only rejects
            // through arithmetic in `_afterSwap`, which `priceBefore` being unset cannot reach.
            if (_isHookRejection(reason)) {
                ++ghost_hookRejections;
                ghost_lastRejection = reason;
            }
            return false;
        }
    }

    /// @dev Whether a revert came from the hook rather than from the pool. The pool manager wraps a hook
    /// revert in `CustomRevert.WrappedError` naming the hook it called, so a pool-level rejection such as
    /// `PriceLimitAlreadyExceeded` is never counted against the hook.
    function _isHookRejection(bytes memory reason) private view returns (bool) {
        if (reason.length < 36) return false;

        bytes4 selector;
        address target;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
            target := mload(add(reason, 0x24))
        }

        return selector == WRAPPED_ERROR_SELECTOR && target == address(hook);
    }

    /// @dev The fee the last swap paid, taken from the `HookFee` the hook emits, and accumulated per
    /// currency so the campaign can check that every wei reached the recipient.
    function _feeFromLogs() private returns (uint256 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == HOOK_FEE_TOPIC) {
                (uint128 fee0, uint128 fee1) = abi.decode(logs[i].data, (uint128, uint128));
                ghost_totalFee0 += fee0;
                ghost_totalFee1 += fee1;
                fee += uint256(fee0) + uint256(fee1);
            }
        }
    }

    /// @dev INV-01. Valued at the beginning-of-block price, a swap may not receive more than it paid.
    function _assertBound(BalanceDelta delta) private {
        (uint160 price,) = _checkpoint();
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        if (price == 0 || amount0 == 0 || amount1 == 0) return;

        uint256 slack = _boundSlack(price);

        if (amount0 > 0) {
            uint256 received0 = uint256(uint128(amount0));
            uint256 paid1 = uint256(uint128(-amount1));
            assertGe(
                paid1 + slack,
                _value0In1(received0, price, false),
                "INV-01: currency0 was bought below the beginning-of-block price"
            );
        } else {
            uint256 paid0 = uint256(uint128(-amount0));
            uint256 received1 = uint256(uint128(amount1));
            assertLe(
                received1,
                _value0In1(paid0, price, true) + slack,
                "INV-01: currency0 was sold above the beginning-of-block price"
            );
        }

        ++ghost_boundChecks;
    }

    /// @dev The most a sandwich can come out ahead purely through the bound's resolution. Each of the
    /// attacker's two legs is bounded once, and each bound is loose by at most {_boundSlack}.
    function sandwichTolerance() public view returns (int256) {
        return int256(2 * _boundSlack(_valuationPrice()));
    }

    /**
     * @dev How far a fill can sit from the bound recomputed here.
     *
     * The hook converts one way and this assertion converts back, and a round trip loses more than either
     * leg. Each `mulDiv` loses under a unit, the first loss of each leg is carried across by that leg's
     * ratio, and the two ratios are the square root of the price and the price itself.
     */
    function _boundSlack(uint160 sqrtPriceX96) private pure returns (uint256) {
        return
            Math.mulDiv(1, sqrtPriceX96, FixedPoint96.Q96, Math.Rounding.Ceil) + _value0In1(1, sqrtPriceX96, true) + 2;
    }

    /// @dev `amount0` valued in currency1 at `sqrtPriceX96`.
    function _value0In1(uint256 amount0, uint160 sqrtPriceX96, bool roundUp) private pure returns (uint256) {
        Math.Rounding rounding = roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor;
        uint256 half = Math.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96, rounding);

        return Math.mulDiv(half, sqrtPriceX96, FixedPoint96.Q96, rounding);
    }

    /// @dev The price this block's swaps are measured against. Before the block's first swap the checkpoint
    /// still holds an older block's, and the pool's own price is what the first swap will record.
    function _valuationPrice() private view returns (uint160 price) {
        uint48 blockNumber;
        (price, blockNumber) = _checkpoint();
        if (blockNumber != uint48(block.number) || price == 0) (price,,,) = manager.getSlot0(poolId);
    }

    /// @dev What an actor holds, valued in currency1 at `price`.
    function _measureValue(address who, uint160 price) private view returns (int256) {
        return int256(_balanceOf(key.currency1, who) + _value0In1(_balanceOf(key.currency0, who), price, false));
    }

    function _runSandwichLegs(address attacker, address prey, uint256 size, uint256 victim, bool openWithBuy)
        private
        returns (bool)
    {
        bool zeroForOneOpen = !openWithBuy;
        int256 open = openWithBuy ? int256(size) : -int256(size);
        int256 close = openWithBuy ? -int256(size) : int256(size);

        if (!_checkedSwap(attacker, zeroForOneOpen, open)) return false;
        _checkedSwap(prey, zeroForOneOpen, openWithBuy ? int256(victim) : -int256(victim));

        return _checkedSwap(attacker, !zeroForOneOpen, close);
    }

    function _recordSandwich(address attacker, int256 opening, uint160 price) private returns (int256 pnl) {
        pnl = _measureValue(attacker, price) - opening;
        if (pnl > ghost_bestSandwichPnl) ghost_bestSandwichPnl = pnl;
    }

    function _modify(address actor, int24 lower, int24 upper, int256 liquidityDelta, bytes32 salt)
        private
        returns (bool)
    {
        if (lower <= -TICK_WINDOW_EDGE || upper >= TICK_WINDOW_EDGE || lower >= upper) return false;

        vm.prank(actor);
        try modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: salt}),
            ""
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _countSwap() private {
        if (block.number == _lastSwapBlock) {
            if (++_swapsThisBlock == 2) ++ghost_multiSwapBlocks;
        } else {
            _lastSwapBlock = block.number;
            _swapsThisBlock = 1;
        }
    }

    function _floor(int24 tick) private view returns (int24) {
        int24 compressed = tick / key.tickSpacing;
        if (tick < 0 && tick % key.tickSpacing != 0) compressed--;

        return compressed * key.tickSpacing;
    }
}
