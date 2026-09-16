// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.2) (src/general/AntiSandwichHook.sol)

pragma solidity ^0.8.26;

// External imports
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
// Internal imports
import {BaseDynamicAfterFee} from "../fee/BaseDynamicAfterFee.sol";

/**
 * @dev This hook is inspired by the sandwich-resistant AMM design introduced
 * https://www.umbraresearch.xyz/writings/sandwich-resistant-amm[here]. Specifically,
 * this hook guarantees that no swaps get filled at a price better than the price at
 * the beginning of the slot window (i.e. one block), up to rounding.
 *
 * That price is recorded at the block's first swap, and any excess a later swap gains over it is taken as a
 * hook fee. A sandwich therefore closes no better than the price its opening leg moved away from, so it cannot
 * turn a profit.
 *
 * In order to use this hook, the inheriting contract must implement the {_afterSwapHandler} function
 * to determine how to handle the collected fees from the anti-sandwich mechanism.
 *
 * NOTE: The price is read at the block's first swap, which is the price the block opened with: in Uniswap v4
 * only a swap moves it, so liquidity changes and donations landing earlier in the block doesn't.
 *
 * NOTE: A block whose price moved far is expensive for everyone trading in it afterwards, since they are all
 * held to the opening price.
 *
 * NOTE: The hook only takes, it never pays. A swap filled better than the recorded price has the
 * difference taken as a fee, while a swap filled worse keeps that fill and receives nothing. A swapper whose
 * fill was worsened, by liquidity withdrawn after the block's first swap for example, is not compensated:
 * the mechanism removes an attacker's profit rather than restoring a victim's loss.
 *
 * NOTE: Only swaps are bounded. An attacker can supply the liquidity a victim trades through and
 * withdraw it in the same block, and an attack whose legs sit in different blocks is measured against a
 * price its own opening leg set. Consider combining with a JIT protection mechanism such as
 * https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/general/LiquidityPenaltyHook.sol[LiquidityPenaltyHook].
 *
 * IMPORTANT: {TargetOutOfRange} refuses a swap that would owe more than a `BalanceDelta` holds, rather than
 * charge it nothing. Reaching it needs the price to cross most of the tick range inside one block, which
 * needs liquidity thin enough for a single swap to do that. Consider how widely liquidity is provided before
 * deploying.
 *
 * IMPORTANT: The fee is a sandwich's own gain, so {_afterSwapHandler} must not pay it to in-range liquidity.
 * An attacker can supply that liquidity and collect the fee back, whether it is paid in the same block or a
 * later one.
 *
 * WARNING: A price move made inside a block is not corrected inside it, since a correcting trade and a
 * sandwich's closing leg are the same trade. Correction waits for the next block, where the checkpoint has
 * reset to the moved price and trading away from it is free. Arbitrage is delayed a block, not discouraged.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v1.1.0_
 */
abstract contract AntiSandwichHook is BaseDynamicAfterFee {
    using StateLibrary for IPoolManager;

    /// @dev A swap ran against a pool holding no beginning-of-block price to hold it to.
    error CheckpointNotSet();

    /// @dev The swap would owe more than a `BalanceDelta` holds, so it cannot be charged what it owes.
    error TargetOutOfRange();

    /// @dev The pool price at a block's first swap, and the block it was recorded in.
    struct Checkpoint {
        uint160 sqrtPriceX96;
        uint48 blockNumber;
    }

    /// @dev Largest amount a `BalanceDelta` carries on one side.
    uint256 private constant MAX_BALANCE_DELTA = uint256(uint128(type(int128).max));

    /// @dev Maps each pool to its last checkpoint.
    mapping(PoolId id => Checkpoint checkpoint) private _lastCheckpoints;

    /// @dev Records the pool price at the block's first swap. Later swaps in the block leave it untouched.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Checkpoint storage checkpoint = _lastCheckpoints[key.toId()];
        uint48 currentBlock = _getBlockNumber();

        // A checkpoint holding no price has not been taken, whatever block it claims. Without that clause a
        // pool whose first swap lands in block zero would never take one, and every swap in it would revert.
        if (checkpoint.blockNumber != currentBlock || checkpoint.sqrtPriceX96 == 0) {
            checkpoint.blockNumber = currentBlock;
            (checkpoint.sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev Returns the block a swap belongs to.
     *
     * IMPORTANT: An override must return one value per block and a different one in the next. A value that
     * moves within a block re-records the price on every swap, which removes the protection. One that never
     * moves anchors the pool to a single price. Both fail silently.
     */
    function _getBlockNumber() internal view virtual returns (uint48) {
        return uint48(block.number);
    }

    /// @dev Returns the checkpoint `poolId` holds. A pool never swapped in holds a zero one.
    function getLastCheckpoint(PoolId poolId) public view virtual returns (Checkpoint memory) {
        return _lastCheckpoints[poolId];
    }

    /**
     * @dev Returns the target `delta` is held to, and whether it applies.
     *
     * The unspecified side carries the target, so an exact input reads it as a ceiling on what the swap keeps
     * and an exact output as a floor on what it pays. {BaseDynamicAfterFee-_afterSwap} takes the difference
     * either way.
     *
     * Every rounding favors the swapper, so a swap that did not beat the recorded price is never charged. The
     * target is loose by the conversion's resolution in exchange, which grows with the price but never with
     * the size of a swap, while the slippage a sandwich pays to open grows with its size.
     *
     * NOTE: No fee is taken where the target is a ceiling past what a `BalanceDelta` carries, and that
     * changes nothing: such a ceiling already sits above every amount the swap could have received. The same
     * overflow on a floor does bind, and reverts rather than charging nothing.
     */
    function _getTargetUnspecified(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal view virtual override returns (uint256 targetUnspecifiedAmount, bool applyTarget) {
        uint256 sqrtPriceX96 = _lastCheckpoints[key.toId()].sqrtPriceX96;
        if (sqrtPriceX96 == 0) revert CheckpointNotSet();

        bool exactInput = params.amountSpecified < 0;
        bool unspecifiedIsCurrency1 = exactInput == params.zeroForOne;

        // The specified amount as the swap executed it, which the target for the unspecified side is calculated from.
        uint256 specifiedAmount = SignedMath.abs(unspecifiedIsCurrency1 ? delta.amount0() : delta.amount1());

        // The ratio that carries one currency into the other.
        (uint256 multiplier, uint256 divisor) =
            unspecifiedIsCurrency1 ? (sqrtPriceX96, FixedPoint96.Q96) : (FixedPoint96.Q96, sqrtPriceX96);

        // An exact input rounds its ceiling up and an exact output rounds its floor down, so the wei that
        // rounding decides always goes to the swapper.
        Math.Rounding rounding = exactInput ? Math.Rounding.Ceil : Math.Rounding.Floor;

        // Most either step may take while its result stays inside a `BalanceDelta`.
        uint256 largest = Math.mulDiv(MAX_BALANCE_DELTA, divisor, multiplier);

        if (specifiedAmount <= largest) {
            // The first step applies the square root of the price, the second completes the conversion.
            uint256 halfway = Math.mulDiv(specifiedAmount, multiplier, divisor, rounding);
            if (halfway <= largest) return (Math.mulDiv(halfway, multiplier, divisor, rounding), true);
        }

        // Past that the two readings of the target part. A floor still binds, and no expressible amount
        // satisfies it, so the swap cannot be held to the price and is refused.
        if (!exactInput) revert TargetOutOfRange();

        // A ceiling cannot bind, since the amount it caps came out of a `BalanceDelta` and is therefore
        // smaller. Charging nothing is not a concession here, it is the same answer the ceiling would give.
        return (type(uint256).max, false);
    }

    /**
     * @dev Set the hook permissions, specifically `beforeSwap`, `afterSwap`, and `afterSwapReturnDelta`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
