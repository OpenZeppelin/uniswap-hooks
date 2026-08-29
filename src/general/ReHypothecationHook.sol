// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.2) (src/general/ReHypothecationHook.sol)

pragma solidity ^0.8.24;

// External imports
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
// Internal imports
import {BaseHook} from "../base/BaseHook.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

/**
 * @dev A Uniswap V4 hook that enables liquidity rehypothecation into external yield sources.
 *
 * Allows users to deposit assets into external yield-generating sources (i.e. ERC-4626 vaults or lending protocols)
 * while maintaining that same liquidity available for swaps, by performing Just-in-Time (JIT) liquidity provisioning.
 *
 * Assets earn yield at the yield sources when idle, before being temporarily injected as liquidity into the pool only
 * when needed for swap execution, then immediately withdrawn back to yield sources to continue earning yield.
 *
 * Conceptually, the hook acts as an intermediary that manages:
 * - the user-facing ERC20 share token (representing rehypothecated liquidity).
 * - the underlying relationship between yield sources deposits and the pool's liquidity.
 *
 * Since the hook must own the liquidity positions in both the external yield sources and the pool in order to transfer it
 * between the two, a single hook-owned liquidity position is shared between all the liquidity providers, defaulting to a
 * UniswapV2 like full-range position.
 *
 * NOTE: Since the hook owns the single liquidity position, liquidity must be added and removed in the same ratio as the
 * balances in the yield sources.
 *
 * NOTE: Since the hook owns the single liquidity position, it is possible to perform "leveraged liquidity" strategies,
 * which would give better pricing to swappers at the cost of the profitability of LP's and increased risks. See {_getLiquidityToUse}
 *
 * NOTE: A pool must be seeded via {seedLiquidity} before liquidity can be added through {addReHypothecatedLiquidity}.
 * Seeding is allowed whenever the pool has no outstanding shares, i.e. at genesis or to revive the pool after a full
 * withdrawal. The seed sets the ratio and mints shares as `sqrt(amount0 * amount1)`, in a UniswapV2 like fashion.
 * From there, a share represents a proportional claim over the hook's balances in the yield sources.
 *
 * WARNING: As the assets are rehypothecated into external yield sources, there is direct exposure to their risks,
 * such as variations in the yield rates, rebalances, impermanent loss, and other risks associated.
 *
 * WARNING: This hook relies on the PoolManager singleton token reserves for flash accounting debts and credits during swaps.
 * During `afterSwap`, the hook briefly generates token debts to the PoolManager even before users transfer their swap tokens.
 * As a consequence, the PoolManager singleton may lack sufficient reserves for illiquid tokens in the instants between the swap
 * executed and the posterior payment from the user, preventing swaps from being executed until the PoolManager accumulates enough tokens.
 * Although it is very unlikely to happen, note that direct liquidity provision to the pool is disabled, so the hook is the sole
 * liquidity provider for its pool.
 *
 * WARNING: Liquidity additions and removals may be affected by slippage. Users can protect against unexpected slippage
 * in general by verifying the amount received is as expected, using a wrapper that performs these checks.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis.
 * We do not give any warranties and will not be liable for any losses incurred through any use of
 * this code base.
 * _Available since v1.2.0_
 */
abstract contract ReHypothecationHook is BaseHook, ERC20, ReentrancyGuardTransient {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for *;
    using Math for uint256;
    using SafeERC20 for IERC20;
    using TransientSlot for *;
    using SlotDerivation for *;

    /// @dev The pool key for the hook. Note that the hook supports only one pool key.
    PoolKey private _poolKey;

    /*
     * @dev The ERC-7201 namespaced transient storage slot for this hook.
     * keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReHypothecationHook")) - 1)) & ~bytes32(uint256(0xff))
    */
    bytes32 private constant REHYPOTHECATION_HOOK_SLOT =
        0x23f8264cc98f1c05acfa1795f9fb9efa795bb6c05987a0477bcc1622ab5aca00;

    /// @dev The offset of the just-in-time position lower tick within {REHYPOTHECATION_HOOK_SLOT}.
    uint256 private constant TICK_LOWER_OFFSET = 0;

    /// @dev The offset of the just-in-time position upper tick within {REHYPOTHECATION_HOOK_SLOT}.
    uint256 private constant TICK_UPPER_OFFSET = 1;

    /// @dev The offset of the JIT lock flag within {REHYPOTHECATION_HOOK_SLOT}.
    uint256 private constant JIT_LOCK_OFFSET = 2;

    /// @dev Error thrown when trying to initialize a pool that has already been initialized.
    error AlreadyInitialized();

    /// @dev Error thrown when attempting to interact with a pool that has not been initialized.
    error NotInitialized();

    /// @dev Error thrown when attempting to add or remove liquidity with zero shares.
    error ZeroShares();

    /// @dev Error thrown when the message value doesn't match the expected amount for native ETH deposits.
    error InvalidMsgValue();

    /// @dev Error thrown when the refund fails.
    error RefundFailed();

    /// @dev Error thrown when a third party attempts to provide or remove liquidity directly on the pool.
    error LiquidityNotAllowed();

    /// @dev Error thrown when adding liquidity before the pool has been seeded.
    error NotSeeded();

    /// @dev Error thrown when seeding a pool that still has outstanding shares.
    error AlreadySeeded();

    /// @dev Error thrown when a seed would mint fewer than the minimum safe initial `shares`, given `minShares`.
    error InsufficientSeed(uint256 shares, uint256 minShares);

    /// @dev Error thrown when a liquidity operation and the just-in-time settlement would overlap,
    /// to prevent reentrancy across the JIT lock.
    error JITLocked();

    /**
     * @dev Emitted when a `sender` adds rehypothecated `shares` to the `poolKey` pool,
     *  transferring `amount0` of `currency0` and `amount1` of `currency1` to the hook.
     */
    event ReHypothecatedLiquidityAdded(
        address indexed sender, PoolKey indexed poolKey, uint256 shares, uint256 amount0, uint256 amount1
    );

    /**
     * @dev Emitted when a `sender` removes rehypothecated `liquidity` from the `poolKey` pool,
     *  receiving `amount0` of `currency0` and `amount1` of `currency1` from the hook.
     */
    event ReHypothecatedLiquidityRemoved(
        address indexed sender, PoolKey indexed poolKey, uint256 shares, uint256 amount0, uint256 amount1
    );

    /**
     * @dev Returns the `poolKey` for the hook pool. Note that the hook supports only one pool key.
     */
    function getPoolKey() public view returns (PoolKey memory poolKey) {
        return _poolKey;
    }

    /**
     * @dev Initialize the hook's `poolKey` pool. The key stored by the hook is unique and
     * should not be modified so that it can safely be used across the hook's lifecycle.
     * Note that the hook supports only one pool key.
     *
     * WARNING: Pool initialization is permissionless and permanently binds the hook to the first key it sees,
     * so a third party can front-run it with an unintended pool. Initialize the pool atomically with the hook's
     * deployment, or override this function to reject an unexpected key.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (address(_poolKey.hooks) != address(0)) revert AlreadyInitialized();
        _poolKey = key;
        return this.beforeInitialize.selector;
    }

    /**
     * @dev Seeds the pool with its first liquidity, depositing `amount0` of `currency0` and `amount1` of
     * `currency1` into the yield sources and minting `sqrt(amount0 * amount1)` shares to the caller, in a
     * UniswapV2 like fashion. The deposited amounts set the ratio at which {addReHypothecatedLiquidity}
     * prices every later addition.
     *
     * Callable permissionlessly whenever the pool has no outstanding shares: at genesis, or to revive the pool
     * after a full withdrawal. The minted shares must be at least `100 * 10 ** _decimalsOffset()`, so the supply
     * dominates the virtual-shares offset used in {_shareToAmount} and the share price cannot be inflated.
     *
     * Returns the `shares` minted and a balance `delta` representing the assets deposited into the hook.
     *
     * NOTE: The amounts should be provided close to the pool's current price, otherwise part of the seeded
     * liquidity may sit idle until swaps rebalance it. See {_getLiquidityToUse}.
     *
     * WARNING: A third party can front-run the intended seed with a heavily skewed ratio. Since
     * {_getLiquidityToUse} is bounded by the scarcer side, the hook is then left with negligible usable liquidity
     * and cannot serve swaps. Deposited assets stay redeemable, and seeding reopens once the supply returns to
     * zero. Consider seeding atomically with pool initialization, or overriding this function to restrict the caller.
     *
     * Requirements:
     * - Pool must be initialized
     * - Pool must have no outstanding shares (`totalSupply() == 0`)
     * - Resulting shares must be at least `100 * 10 ** _decimalsOffset()`
     * - Sender must have approved the hook to spend the required tokens
     */
    function seedLiquidity(uint256 amount0, uint256 amount1)
        public
        payable
        virtual
        nonReentrant
        returns (uint256 shares, BalanceDelta delta)
    {
        if (address(_poolKey.hooks) == address(0)) revert NotInitialized();
        if (_isJITLocked()) revert JITLocked();
        if (totalSupply() != 0) revert AlreadySeeded();

        shares = Math.sqrt(amount0 * amount1);
        uint256 minShares = 100 * 10 ** uint256(_decimalsOffset());
        if (shares < minShares) revert InsufficientSeed(shares, minShares);

        _transferFromSenderToHook(_poolKey.currency0, amount0, msg.sender);
        _transferFromSenderToHook(_poolKey.currency1, amount1, msg.sender);

        _depositToYieldSource(_poolKey.currency0, amount0);
        _depositToYieldSource(_poolKey.currency1, amount1);

        _mint(msg.sender, shares);

        emit ReHypothecatedLiquidityAdded(msg.sender, _poolKey, shares, amount0, amount1);

        return (shares, toBalanceDelta(-int256(amount0).toInt128(), -int256(amount1).toInt128()));
    }

    /**
     * @dev Adds rehypothecated liquidity to their corresponding yield sources and mints `shares` to the `receiver`.
     *
     * Liquidity is added in the ratio determined by the hook's existing balances in yield sources.
     * Assets are deposited into yield sources where they earn yield when idle and can be dynamically
     *  used as pool liquidity during swaps.
     *
     * Returns a balance `delta` representing the assets deposited into the hook.
     *
     * Requirements:
     * - Pool must be initialized
     * - Pool must have been seeded (see {seedLiquidity})
     * - Sender must have sufficient token balances
     * - Sender must have approved the hook to spend the required tokens
     */
    function addReHypothecatedLiquidity(uint256 shares)
        public
        payable
        virtual
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (address(_poolKey.hooks) == address(0)) revert NotInitialized();
        if (_isJITLocked()) revert JITLocked();
        if (totalSupply() == 0) revert NotSeeded();
        if (shares == 0) revert ZeroShares();

        (uint256 amount0, uint256 amount1) = previewMint(shares);

        _transferFromSenderToHook(_poolKey.currency0, amount0, msg.sender);
        _transferFromSenderToHook(_poolKey.currency1, amount1, msg.sender);

        // Skip zero-amount deposits, which some yield sources reject (e.g. when one side is proportionally empty)
        if (amount0 > 0) _depositToYieldSource(_poolKey.currency0, amount0);
        if (amount1 > 0) _depositToYieldSource(_poolKey.currency1, amount1);

        _mint(msg.sender, shares);

        emit ReHypothecatedLiquidityAdded(msg.sender, _poolKey, shares, amount0, amount1);

        return toBalanceDelta(-int256(amount0).toInt128(), -int256(amount1).toInt128());
    }

    /**
     * @dev Removes rehypothecated liquidity from their corresponding yield sources and burns `shares` from the caller.
     *
     * Liquidity is withdrawn in the ratio determined by the hook's existing balances in yield sources.
     * Assets are withdrawn from yield sources where they were generating yield, allowing users to exit their
     * rehypothecated position and reclaim their underlying tokens.
     *
     * Returns a balance `delta` representing the assets withdrawn from the hook.
     *
     * Requirements:
     * - Pool must be initialized
     * - Sender must have sufficient shares for the desired liquidity withdrawal
     */
    function removeReHypothecatedLiquidity(uint256 shares) public virtual nonReentrant returns (BalanceDelta delta) {
        if (address(_poolKey.hooks) == address(0)) revert NotInitialized();
        if (_isJITLocked()) revert JITLocked();
        if (shares == 0) revert ZeroShares();

        (uint256 amount0, uint256 amount1) = previewRedeem(shares);

        _burn(msg.sender, shares);

        // Skip zero-amount withdrawals, which some yield sources reject (e.g. when one side is proportionally empty)
        if (amount0 > 0) _withdrawFromYieldSource(_poolKey.currency0, amount0);
        if (amount1 > 0) _withdrawFromYieldSource(_poolKey.currency1, amount1);

        _transferFromHookToSender(_poolKey.currency0, amount0, msg.sender);
        _transferFromHookToSender(_poolKey.currency1, amount1, msg.sender);

        emit ReHypothecatedLiquidityRemoved(msg.sender, _poolKey, shares, amount0, amount1);

        return toBalanceDelta(int256(amount0).toInt128(), int256(amount1).toInt128());
    }

    /**
     * @dev Hook executed before a swap operation to provide liquidity from rehypothecated assets.
     *
     * Gets the amount of liquidity to be provided from yield sources and temporarily adds it to the pool,
     * in a Just-in-Time provision of liquidity.
     *
     * Note that at this point there are no actual transfers of tokens happening to the pool, instead,
     * thanks to the Flash Accounting model, this addition creates a currencyDelta to the hook, which
     * must be settled during the `_afterSwap` function before locking the poolManager again.
     */
    function _beforeSwap(
        address, /* sender */
        PoolKey calldata, /* key */
        SwapParams calldata, /* params */
        bytes calldata /* hookData */
    )
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Take the JIT lock: block liquidity operations from reentering mid-settlement, and block a swap
        // from running inside a liquidity operation or another swap. Released at the end of `_afterSwap`.
        if (_reentrancyGuardEntered() || _isJITLocked()) revert JITLocked();
        _setJITLocked(true);

        // Snapshot the position's tick bounds so `afterSwap` removes exactly what is added here.
        _snapshotActiveTicks();

        // Get the liquidity to be used from the amounts currently deposited in the yield sources
        uint256 liquidityToUse = _getLiquidityToUse(_activeTickLower(), _activeTickUpper());
        if (liquidityToUse > 0) _modifyLiquidity(liquidityToUse.toInt256());

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev Hook executed after a swap operation to remove temporary liquidity and rebalance assets.
     *
     * Removes the liquidity that was temporarily added in `_beforeSwap`, and resolves the hook's
     * deltas in each currency in order to neutralize any pending debits or credits.
     */
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata, /* params */
        BalanceDelta, /* delta */
        bytes calldata /* hookData */
    )
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        // Remove all of the hook owned liquidity from the pool
        uint128 liquidity = _getHookPositionLiquidity();
        if (liquidity > 0) {
            _modifyLiquidity(-liquidity.toInt256());

            // Take or settle any pending deltas with the PoolManager
            _resolveHookDelta(key.currency0);
            _resolveHookDelta(key.currency1);
        }

        // Release the JIT lock once settlement (and its external yield-source calls) is complete.
        _setJITLocked(false);

        return (this.afterSwap.selector, 0);
    }

    /**
     * @dev Takes or settles any pending `currencyDelta` delta with the poolManager by transferring from the yield
     * sources to the poolManager and vice versa, effectively neutralizing the Flash Accounting deltas before being
     * able to lock the poolManager again.
     */
    function _resolveHookDelta(Currency currency) internal virtual {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (currencyDelta > 0) {
            currency.take(poolManager, address(this), currencyDelta.toUint256(), false);
            _depositToYieldSource(currency, currencyDelta.toUint256());
        }
        if (currencyDelta < 0) {
            _withdrawFromYieldSource(currency, (-currencyDelta).toUint256());
            currency.settle(poolManager, address(this), (-currencyDelta).toUint256(), false);
        }
    }

    /**
     * @dev Blocks direct liquidity provision to the pool by third parties, so the hook remains the pool's sole
     * liquidity provider. This prevents external positions from interfering with the hook's just-in-time liquidity,
     * such as saturating the position's tick boundaries and reverting subsequent swaps.
     *
     * Note that the hook's own just-in-time liquidity provisioning is unaffected, since the `PoolManager` skips hook
     * callbacks when the hook itself is modifying liquidity.
     */
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /**
     * @dev Blocks direct liquidity removal from the pool by third parties. See {_beforeAddLiquidity}.
     */
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /**
     * @dev Preview the amounts of currency0 and currency1 required for minting a specific amount of shares.
     *
     * NOTE: Rounds up, benefiting current liquidity providers.
     */
    function previewMint(uint256 shares) public view virtual returns (uint256 amount0, uint256 amount1) {
        return _sharesToAmounts(shares, Math.Rounding.Ceil);
    }

    /**
     * @dev Preview the amounts of currency0 and currency1 to be received for redeeming a specific amount of shares.
     *
     * NOTE: Rounds down, benefiting current liquidity providers.
     */
    function previewRedeem(uint256 shares) public view virtual returns (uint256 amount0, uint256 amount1) {
        return _sharesToAmounts(shares, Math.Rounding.Floor);
    }

    /**
     * @dev Calculates the amounts of currency0 and currency1 equivalent to a given amount of `shares`, as a
     * proportional claim over the hook's balances in the yield sources, using the given rounding direction.
     *
     * Reverts with {NotSeeded} when no shares have been minted yet, since the pool has no defined ratio before
     * {seedLiquidity}.
     */
    function _sharesToAmounts(uint256 shares, Math.Rounding rounding)
        internal
        view
        virtual
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = _shareToAmount(shares, _poolKey.currency0, rounding);
        amount1 = _shareToAmount(shares, _poolKey.currency1, rounding);
    }

    /**
     * @dev Converts a given `shares` amount to the corresponding `currency` amount, as its proportional claim
     * over the hook's balance of `currency` in the yield source, using the given rounding direction.
     *
     * Uses an EIP-4626 like virtual offset (see {_decimalsOffset}) to defend the share price against inflation,
     * so a share is worth `(balance + 1) / (totalSupply + 10 ** _decimalsOffset())` of the `currency` balance.
     * Reverts with {NotSeeded} before the pool is seeded.
     */
    function _shareToAmount(uint256 shares, Currency currency, Math.Rounding rounding)
        internal
        view
        virtual
        returns (uint256 amount)
    {
        uint256 supply = totalSupply();
        if (supply == 0) revert NotSeeded();
        return shares.mulDiv(_getAmountInYieldSource(currency) + 1, supply + 10 ** uint256(_decimalsOffset()), rounding);
    }

    /**
     * @dev Returns the decimal offset used for the EIP-4626 like virtual shares that defend the share price
     * against inflation. The initial supply minted by {seedLiquidity} is required to be at least
     * `100 * 10 ** _decimalsOffset()`, keeping the maximum share price drift around 1%.
     *
     * Defaults to `6`, which suits most token pairs. Can be overridden to strengthen the defense with a higher
     * offset, at the cost of a larger minimum seed, for example for high-decimal pairs.
     */
    function _decimalsOffset() internal view virtual returns (uint8) {
        return 6;
    }

    /**
     * @dev Calculates the `liquidity` to be provided just-in-time for incoming swaps.
     *
     * By default, returns the maximum liquidity that can be provided given the balances the hook can
     * currently withdraw from the yield sources (see {_getMaxWithdrawFromYieldSource}), so the position
     * removed in `afterSwap` never exceeds what the yield sources can return in the same transaction.
     *
     * Since the internal pool price (ratio of currency0 to currency1) must be preserved for providing
     * liquidity to the single hook-owned position range, not necessarily all the assets in the yield
     * sources may be utilizable as liquidity if the ratio has diverged from the internal pool price.
     *
     * i.e if the pool price is currently [1:1], but due to divergences in the yield sources the assets
     * are [100, 110], then only [100, 100] is utilizable and will be returned by this function in equivalent
     * liquidity units, as it is the maximum amount of assets utilizable given the current pool price ratio.
     *
     * NOTE: Since liquidity is provided and withdrawn transiently during flash accounting, it can be virtually
     * inflated for performing "leveraged liquidity" strategies, which would give better pricing to swappers at
     * the cost of the profitability of LP's and increased risks.
     *
     * @param tickLower The lower tick of the position the liquidity is sized for.
     * @param tickUpper The upper tick of the position the liquidity is sized for.
     */
    function _getLiquidityToUse(int24 tickLower, int24 tickUpper) internal view virtual returns (uint256) {
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolKey.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            _getMaxWithdrawFromYieldSource(_poolKey.currency0),
            _getMaxWithdrawFromYieldSource(_poolKey.currency1)
        );
    }

    /**
     * @dev Snapshots the just-in-time position's tick bounds into transient storage, so the same bounds are used
     * to add, read and remove the position across a swap. Called at the start of `beforeSwap`.
     */
    function _snapshotActiveTicks() private {
        REHYPOTHECATION_HOOK_SLOT.offset(TICK_LOWER_OFFSET).asInt256().tstore(getTickLower());
        REHYPOTHECATION_HOOK_SLOT.offset(TICK_UPPER_OFFSET).asInt256().tstore(getTickUpper());
    }

    /// @dev The lower tick of the just-in-time position snapshotted for the current swap.
    function _activeTickLower() private view returns (int24) {
        return int24(REHYPOTHECATION_HOOK_SLOT.offset(TICK_LOWER_OFFSET).asInt256().tload());
    }

    /// @dev The upper tick of the just-in-time position snapshotted for the current swap.
    function _activeTickUpper() private view returns (int24) {
        return int24(REHYPOTHECATION_HOOK_SLOT.offset(TICK_UPPER_OFFSET).asInt256().tload());
    }

    /// @dev Sets whether the JIT lock (`beforeSwap` through `afterSwap`) is held.
    function _setJITLocked(bool active) private {
        REHYPOTHECATION_HOOK_SLOT.offset(JIT_LOCK_OFFSET).asBoolean().tstore(active);
    }

    /// @dev Whether the JIT lock is currently held.
    function _isJITLocked() private view returns (bool) {
        return REHYPOTHECATION_HOOK_SLOT.offset(JIT_LOCK_OFFSET).asBoolean().tload();
    }

    /**
     * @dev Retrieves the current `liquidity` of the hook owned liquidity position in the `_poolKey` pool.
     *
     * NOTE: Given that just-in-time liquidity provisioning is performed, this function will only return non-zero values
     * while the liquidity is briefly inside the pool, which is exclusively between `beforeSwap` and `afterSwap`). It will
     * return zero in any other point in the hook lifecycle. For determining the hook balances in any other point, use
     * {_getAmountInYieldSource}.
     */
    function _getHookPositionLiquidity() internal view virtual returns (uint128 liquidity) {
        bytes32 positionKey =
            Position.calculatePositionKey(address(this), _activeTickLower(), _activeTickUpper(), bytes32(0));
        return poolManager.getPositionLiquidity(_poolKey.toId(), positionKey);
    }

    /**
     * @dev Returns the lower tick boundary for the hook's liquidity position.
     *
     * Can be overridden to customize the tick boundary.
     */
    function getTickLower() public view virtual returns (int24) {
        return TickMath.minUsableTick(_poolKey.tickSpacing);
    }

    /**
     * @dev Returns the upper tick boundary for the hook's liquidity position.
     *
     * Can be overridden to customize the tick boundary.
     */
    function getTickUpper() public view virtual returns (int24) {
        return TickMath.maxUsableTick(_poolKey.tickSpacing);
    }

    /**
     * @dev Modifies the hook's liquidity position in the pool, at the tick bounds snapshotted for the current
     * swap (see {_snapshotActiveTicks}).
     *
     * Positive liquidityDelta adds liquidity, while negative removes it.
     */
    function _modifyLiquidity(int256 liquidityDelta) internal virtual returns (BalanceDelta delta) {
        (delta,) = poolManager.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({
                tickLower: _activeTickLower(),
                tickUpper: _activeTickUpper(),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /*
     * @dev Transfers the `amount` of `currency` from the `sender` to the hook.
     */
    function _transferFromSenderToHook(Currency currency, uint256 amount, address sender) internal virtual {
        if (!currency.isAddressZero()) {
            IERC20(Currency.unwrap(currency)).safeTransferFrom(sender, address(this), amount);
        } else {
            if (msg.value < amount) revert InvalidMsgValue();
            if (msg.value > amount) {
                // slither-disable-next-line arbitrary-send-eth
                (bool success,) = msg.sender.call{value: msg.value - amount}("");
                if (!success) revert RefundFailed();
            }
        }
    }

    /**
     * @dev Transfers the `amount` of `currency` from the hook to the `sender`.
     */
    function _transferFromHookToSender(Currency currency, uint256 amount, address sender) internal virtual {
        currency.transfer(sender, amount);
    }

    /**
     * @dev Returns the `yieldSource` address for a given `currency`.
     *
     * Note: Must be implemented and adapted for the desired type of yield sources, such as
     *  ERC-4626 Vaults, or any custom DeFi protocol interface, optionally handling native currency.
     */
    function getCurrencyYieldSource(Currency currency) public view virtual returns (address yieldSource);

    /**
     * @dev Deposits a specified `amount` of `currency` into its corresponding yield source.
     *
     * Note: Must be implemented and adapted for the desired type of yield sources, such as
     *  ERC-4626 Vaults, or any custom DeFi protocol interface, optionally handling native currency.
     */
    function _depositToYieldSource(Currency currency, uint256 amount) internal virtual;

    /**
     * @dev Withdraws a specified `amount` of `currency` from its corresponding yield source.
     *
     * Note: Must be implemented and adapted for the desired type of yield sources, such as
     *  ERC-4626 Vaults, or any custom DeFi protocol interface, optionally handling native currency.
     */
    function _withdrawFromYieldSource(Currency currency, uint256 amount) internal virtual;

    /**
     * @dev Gets the `amount` of `currency` deposited in its corresponding yield source.
     *
     * Note: Must be implemented and adapted for the desired type of yield sources, such as
     *  ERC-4626 Vaults, or any custom DeFi protocol interface, optionally handling native currency.
     */
    function _getAmountInYieldSource(Currency currency) internal view virtual returns (uint256 amount);

    /**
     * @dev Returns the maximum `amount` of `currency` that can currently be withdrawn from its yield source.
     *
     * Used to size the just-in-time liquidity provided during swaps, so the hook never provisions more than it
     * can withdraw back in the same transaction. Share pricing instead uses {_getAmountInYieldSource}, the full
     * reported balance.
     *
     * Defaults to {_getAmountInYieldSource}. Override for yield sources whose immediately-withdrawable amount can
     * be below the reported balance, such as ERC-4626 `maxWithdraw`, or capped, gated or fee-charging sources.
     */
    function _getMaxWithdrawFromYieldSource(Currency currency) internal view virtual returns (uint256) {
        return _getAmountInYieldSource(currency);
    }

    /**
     * Set the hooks permissions, specifically `beforeInitialize`, `beforeSwap`, `afterSwap`.
     * @return permissions The permissions for the hook.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Allows the hook to receive native ETH from the yield sources.
    // solhint-disable-next-line
    receive() external payable virtual {}
}
