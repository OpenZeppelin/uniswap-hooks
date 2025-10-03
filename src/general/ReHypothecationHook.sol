// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/general/ReHypothecationHook.sol)

pragma solidity ^0.8.24;

// External imports
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
// Internal imports
import {BaseHook} from "../base/BaseHook.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

/**
 * @dev A Uniswap V4 hook that enables rehypothecation of liquidity positions.
 *
 * This hook allows users to deposit assets into yield-generating sources (e.g., ERC-4626 vaults)
 * while providing liquidity to Uniswap pools Just-in-Time (JIT) during swaps. Assets earn yield
 * when idle and are temporarily injected as pool liquidity only when needed for swap execution,
 * then immediately withdrawn back to yield sources.
 *
 * Conceptually, the hook acts as an intermediary that manages:
 * - the user-facing ERC20 share token (representing rehypothecated positions), and
 * - the underlying relationship between yield sources and pool liquidity.
 *
 * Key features:
 * - Users can deposit assets into yield sources via the hook and receive ERC20 shares
 *   that represent their rehypothecated liquidity position.
 * - The hook dynamically manages pool liquidity based on available yield source assets,
 *   performing JIT provisioning during swaps.
 * - After swaps, assets are deposited back into yield sources to continue earning yield.
 * - Supports both ERC20 tokens and native ETH by default.
 *
 * NOTE: By default, the hook liquidity position is placed in the entire curve range. Override
 * the `getTickLower` and `getTickUpper` functions to customize the position.
 *
 * NOTE: By default, both canonical and rehypothecated liquidity modifications are allowed. Override
 *  `beforeAddLiquidity` and `beforeRemoveLiquidity` to disable canonical liquidity modifications if desired.
 *
 * WARNING: This hook relies on the PoolManager singleton token reserves for flash accounting during swaps.
 * During `afterSwap`, the hook takes tokens from the PoolManager to settle deltas before users transfer
 * their swap tokens. The PoolManager may lack sufficient reserves for illiquid tokens, preventing
 * swaps until the PoolManager accumulates enough tokens for these small flash loans. This can be mitigated by
 * maintaining some permanent pool liquidity alongside rehypothecated liquidity.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis.
 * We do not give any warranties and will not be liable for any losses incurred through any use of
 * this code base.
 * _Available since v1.1.0_
 */
abstract contract ReHypothecationHook is BaseHook, ERC20, ReentrancyGuardTransient {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for *;
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @dev The pool key for the hook. Note that the hook supports only one pool key.
    PoolKey private _poolKey;

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
     * @dev Sets the `PoolManager` address.
     */
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /**
     * @dev Returns the `poolKey` for the hook pool.
     */
    function getPoolKey() public view returns (PoolKey memory poolKey) {
        return _poolKey;
    }

    /**
     * @dev Initialize the hook's `poolKey`. The stored key by the hook is unique and
     * should not be modified so that it can safely be used across the hook's lifecycle.
     *
     * NOTE: Native ETH is supported by default, which can be disabled by overriding `_beforeInitialize` with:
     * ```solidity
     * function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
     *     if (key.currency0.isAddressZero()) revert UnsupportedCurrency();
     *     return super._beforeInitialize(key);
     * }
     * ```
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (address(_poolKey.hooks) != address(0)) revert AlreadyInitialized();
        _poolKey = key;
        return this.beforeInitialize.selector;
    }

    /**
     * @dev Adds rehypothecated liquidity to yield sources and mints shares to the caller.
     *
     * Liquidity is added in the ratio determined by the hook's existing balances in yield sources.
     * Assets are deposited into yield sources where they earn returns when idle and can be
     * dynamically used as pool liquidity during swaps.
     *
     * Returns a balance `delta` representing the assets deposited into the hook.
     *
     * Requirements:
     * - Pool must be initialized
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
        if (shares == 0) revert ZeroShares();

        (uint256 amount0, uint256 amount1) = _convertSharesToAmounts(shares);

        _transferFromSenderToHook(_poolKey.currency0, amount0, msg.sender);
        _transferFromSenderToHook(_poolKey.currency1, amount1, msg.sender);

        _depositToYieldSource(_poolKey.currency0, amount0);
        _depositToYieldSource(_poolKey.currency1, amount1);

        _mint(msg.sender, shares);

        emit ReHypothecatedLiquidityAdded(msg.sender, _poolKey, shares, amount0, amount1);

        return toBalanceDelta(-int256(amount0).toInt128(), -int256(amount1).toInt128());
    }

    /**
     * @dev Removes rehypothecated liquidity from yield sources and burns caller's shares.
     *
     * Liquidity is withdrawn in the ratio determined by the hook's existing balances in yield sources.
     * Assets are withdrawn from yield sources where they were generating yield, allowing users to
     * exit their rehypothecated position and reclaim their underlying tokens.
     *
     * Returns a balance `delta` representing the assets withdrawn from the hook.
     *
     * Requirements:
     * - Pool must be initialized
     * - Sender must have sufficient shares for the desired liquidity withdrawal
     */
    function removeReHypothecatedLiquidity(uint256 shares) public virtual nonReentrant returns (BalanceDelta delta) {
        if (address(_poolKey.hooks) == address(0)) revert NotInitialized();
        if (shares == 0) revert ZeroShares();

        (uint256 amount0, uint256 amount1) = _convertSharesToAmounts(shares);

        _burn(msg.sender, shares);

        _withdrawFromYieldSource(_poolKey.currency0, amount0);
        _withdrawFromYieldSource(_poolKey.currency1, amount1);

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
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get the liquidity to be used from the amounts currently deposited in the yield sources
        uint256 liquidityToUse = _getLiquidityToUse();
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
    ) internal virtual override returns (bytes4, int128) {
        // Remove all of the hook owned liquidity from the pool
        uint128 liquidity = _getHookPositionLiquidity();
        if (liquidity > 0) {
            _modifyLiquidity(-liquidity.toInt256());

            // Take or settle any pending deltas with the PoolManager
            _resolveHookDelta(key.currency0);
            _resolveHookDelta(key.currency1);
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * @dev Takes or settles any pending `currencyDelta` amount with the poolManager,
     * neutralizing the Flash Accounting deltas before locking the poolManager again.
     */
    function _resolveHookDelta(Currency currency) internal virtual {
        IPoolManager poolManager = poolManager();

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
     * @dev Preview the amounts of currency0 and currency1 required/obtained for a given amount of shares.
     */
    function previewAmountsForShares(uint256 shares) public view virtual returns (uint256 amount0, uint256 amount1) {
        return _convertSharesToAmounts(shares);
    }

    /**
     * @dev Calculates the amounts of currency0 and currency1 required for adding a specific amount of shares.
     *
     * If the hook has not emitted shares yet, the initial deposit ratio is determined by the current pool price.
     * Otherwise, it is determined by ratio of the hook balances in the yield sources.
     */
    function _convertSharesToAmounts(uint256 shares) internal view virtual returns (uint256 amount0, uint256 amount1) {
        // If the hook has not emitted shares yet, then consider `liquidity == shares`
        if (totalSupply() == 0) {
            (uint160 currentSqrtPriceX96,,,) = poolManager().getSlot0(_poolKey.toId());
            return LiquidityAmounts.getAmountsForLiquidity(
                currentSqrtPriceX96,
                TickMath.getSqrtPriceAtTick(getTickLower()),
                TickMath.getSqrtPriceAtTick(getTickUpper()),
                shares.toUint128()
            );
        }
        // If the hook has shares, then deposit proportionally to the hook balances in the yield sources
        else {
            amount0 = _shareToAmount(shares, _poolKey.currency0);
            amount1 = _shareToAmount(shares, _poolKey.currency1);
        }
    }

    /**
     * @dev Converts a given `shares` amount to the corresponding `currency` amount.
     */
    function _shareToAmount(uint256 shares, Currency currency) internal view virtual returns (uint256 amount) {
        uint256 totalAmount = _getAmountInYieldSource(currency);
        if (totalAmount == 0) return 0;
        return FullMath.mulDiv(shares, totalAmount, totalSupply());
    }

    /**
     * @dev Returns the `liquidity` to be provided just-in-time for incoming swaps.
     *
     * By default, returns the maximum liquidity that can be provided with the current
     * balances of the hook in the yield sources.
     *
     * NOTE: Since liquidity is provided and withdrawn transiently during flash accounting, it
     * can be virtually inflated for performing "leveraged liquidity" strategies, which would
     * give better pricing to swappers at the cost of the profitability of LP's and increased risks.
     */
    function _getLiquidityToUse() internal view virtual returns (uint256) {
        (uint160 currentSqrtPriceX96,,,) = poolManager().getSlot0(_poolKey.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(getTickLower()),
            TickMath.getSqrtPriceAtTick(getTickUpper()),
            _getAmountInYieldSource(_poolKey.currency0),
            _getAmountInYieldSource(_poolKey.currency1)
        );
    }

    /**
     * @dev Retrieves the current `liquidity` of the hook owned liquidity position in the `_poolKey` pool.
     *
     * NOTE: Given that just-in-time liquidity provisioning is performed, this function will only return values
     * larger than zero between `beforeSwap` and `afterSwap`, where the liquidity is actually inside the pool.
     * It will return zero in any other point in the hook lifecycle. For determining the hook balances in any other point,
     * use `_getAmountInYieldSource`.
     */
    function _getHookPositionLiquidity() internal view virtual returns (uint128 liquidity) {
        bytes32 positionKey = Position.calculatePositionKey(address(this), getTickLower(), getTickUpper(), bytes32(0));
        return poolManager().getPositionLiquidity(_poolKey.toId(), positionKey);
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
     * @dev Modifies the hook's liquidity position in the pool.
     *
     * Positive liquidityDelta adds liquidity, while negative removes it.
     */
    function _modifyLiquidity(int256 liquidityDelta) internal virtual returns (BalanceDelta delta) {
        (delta,) = poolManager().modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({
                tickLower: getTickLower(),
                tickUpper: getTickUpper(),
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
     * Set the hooks permissions, specifically `beforeInitialize`, `beforeSwap`, `afterSwap`.
     * @return permissions The permissions for the hook.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
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
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Allows the hook to receive native ETH from the yield sources.
    // solhint-disable-next-line
    receive() external payable virtual {}
}
