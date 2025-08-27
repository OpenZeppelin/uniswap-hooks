// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/general/ReHypothecationHook.sol)

pragma solidity ^0.8.24;

// Internal imports
import {BaseHook} from "../base/BaseHook.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";
import {LiquidityMath} from "../utils/LiquidityMath.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "openzeppelin/interfaces/IERC4626.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

// External imports
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

/**
 * @dev A Uniswap V4 hook that enables rehypothecation of liquidity positions.
 *
 * This hook allows users to deposit assets into yield-generating protocols (like ERC4626 vaults)
 * while maintaining the ability to provide liquidity to Uniswap pools. The hook acts as an
 * intermediary that manages the relationship between yield sources and pool liquidity.
 *
 * Key features:
 * - Users can add rehypothecated liquidity by depositing assets into yield sources
 * - The hook dynamically manages pool liquidity based on available yield source assets
 * - Supports both ERC20 tokens and native ETH (with proper implementation)
 * - Implements ERC20 for representing user shares of the rehypothecated position
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 * _Available since v1.1.0_
 */
abstract contract ReHypothecationHook is BaseHook, ERC20 {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for *;

    /// @dev The pool key for the hook. Note that the hook only allows one key.
    PoolKey private _poolKey;

    /// @dev Error thrown when attempting to add or remove zero liquidity.
    error ZeroLiquidity();

    /// @dev Error thrown when trying to initialize a pool key that has already been set.
    error AlreadyInitialized();

    /// @dev Error thrown when attempting to use the hook before the pool key has been initialized.
    error PoolKeyNotInitialized();

    /// @dev Error thrown when the message value doesn't match the expected amount for native ETH deposits.
    error InvalidMsgValue();

    /// @dev Error thrown when a refund of excess ETH fails.
    error RefundFailed();

    /// @dev Error thrown when the calculated amounts for liquidity operations are invalid.
    error InvalidAmounts();

    /// @dev Error thrown when attempting to use an unsupported currency type.
    error InvalidCurrency();

    /**
     * @dev Emitted when an `sender` adds rehypothecated liquidity to the pool, transferring `amount0` of `currency0` and `amount1` of `currency1` to the hook.
     */
    event ReHypothecatedLiquidityAdded(address indexed sender, uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @dev Emitted when an `sender` removes rehypothecated liquidity from the pool, receiving `amount0` of `currency0` and `amount1` of `currency1` from the hook.
     */
    event ReHypothecatedLiquidityRemoved(address indexed sender, uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @dev Sets the `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Adds rehypothecated `liquidity` to the pool, retunns the caller's `delta`, and mints ERC20 shares to them.
     *
     * This function calculates the required amounts of both currencies based on the desired liquidity,
     * transfers the assets from the user, deposits them into yield sources, and mints shares
     * representing the user's position.
     *
     * Note: This function can only be called once the pool is initialized, reverting with `PoolKeyNotInitialized` otherwise.
     * The hook might accept native currency, in which case the function `_depositOnYieldSource` must be implemented to handle it.
     */
    function addReHypothecatedLiquidity(uint128 liquidity) external payable returns (BalanceDelta delta) {
        if (_poolKey.currency1.isAddressZero()) revert PoolKeyNotInitialized();

        if (liquidity == 0) revert ZeroLiquidity();

        delta = _getDeltaForDepositedShares(liquidity);

        uint256 amount0 = int256(-delta.amount0()).toUint256();
        uint256 amount1 = int256(-delta.amount1()).toUint256();

        if (_poolKey.currency0.isAddressZero()) {
            if (msg.value < amount0) revert InvalidMsgValue();
            uint256 refund = msg.value - amount0;
            if (refund > 0) {
                (bool success,) = msg.sender.call{value: refund}("");
                if (!success) revert RefundFailed();
            }
        } else {
            if (msg.value > 0) {
                revert InvalidMsgValue();
            }
            IERC20(Currency.unwrap(_poolKey.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        }
        IERC20(Currency.unwrap(_poolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1);

        _depositOnYieldSource(_poolKey.currency0, amount0);
        _depositOnYieldSource(_poolKey.currency1, amount1);

        _mint(msg.sender, liquidity);

        emit ReHypothecatedLiquidityAdded(msg.sender, liquidity, amount0, amount1);
    }

    /**
     * @dev Removes all rehypothecated liquidity for a given owner and burns their shares.
     *
     * This function calculates the proportional amounts of both currencies based on the owner's
     * share balance, withdraws assets from yield sources, and transfers them to the owner.
     *
     * The owner parameter specifies the address of the user whose liquidity will be removed.
     * The function returns a balance delta representing the assets withdrawn from the hook.
     *
     * Requirements:
     * - Pool must be initialized
     * - Owner must have a positive share balance
     *
     * Note: This function removes ALL liquidity for the owner. For partial withdrawals,
     * consider implementing a separate function or using standard ERC20 transfer mechanisms.
     */
    function removeReHypothecatedLiquidity(address owner) external returns (BalanceDelta delta) {
        if (_poolKey.currency1.isAddressZero()) revert PoolKeyNotInitialized();

        uint256 sharesAmount = balanceOf(owner);
        if (sharesAmount == 0) revert ZeroLiquidity();

        delta = _getDeltaForWithdrawnShares(sharesAmount);

        uint256 amount0 = int256(delta.amount0()).toUint256();
        uint256 amount1 = int256(delta.amount1()).toUint256();

        _burn(owner, sharesAmount);

        _withdrawFromYieldSource(_poolKey.currency0, amount0);
        _withdrawFromYieldSource(_poolKey.currency1, amount1);

        _poolKey.currency0.transfer(owner, amount0);
        _poolKey.currency1.transfer(owner, amount1);

        emit ReHypothecatedLiquidityRemoved(owner, uint128(sharesAmount), amount0, amount1);
    }

    /**
     * @dev Initialize the hook's pool key. The stored key should act immutably so that
     * it can safely be used across the hook's functions.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Check if the pool key is already initialized
        if (address(_poolKey.hooks) != address(0)) revert AlreadyInitialized();

        // Store the pool key to be used in other functions
        _poolKey = key;
        return this.beforeInitialize.selector;
    }

    /**
     * @dev Hook executed before a swap operation to provide liquidity from rehypothecated assets.
     * This function gets the amount of liquidity to be provided from yield sources and temporarily
     * adds it to the pool, in a Just-in-Time provision of liquidity.
     * Note that at this point there's no really transfer of tokens to the pool, this addition of liquidity
     * creates a currencyDelta to the hook, which must be settled in the `_afterSwap` function.
     */
    function _beforeSwap(address, /* sender */ PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get the amount of liquidity to be provided from yield sources
        uint128 liquidityToUse = _getLiquidityToUse(key, params);

        // If there's liquidity to be provided, add it to the pool (in a Just-in-Time provision of liquidity)
        if (liquidityToUse > 0) {
            _modifyLiquidity(liquidityToUse.toInt256());
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev Hook executed after a swap operation to remove temporary liquidity and rebalance assets.
     * This function removes the liquidity that was temporarily added in `_beforeSwap`, and
     * asserts the hook's deltas in each currency in order to zero them.
     */
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata, /* params */
        BalanceDelta, /* delta */
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4, int128) {
        // Get the hook owned liquidity currently in the pool
        uint128 liquidity = _getHookLiquidity(key);
        if (liquidity == 0) {
            return (this.afterSwap.selector, 0);
        }
        // Remove all of the hook owned liquidity from the pool
        _modifyLiquidity(-liquidity.toInt256());

        // Assert the hook's deltas in each currency in order to zero them
        _assertHookDelta(key.currency0);
        _assertHookDelta(key.currency1);

        return (this.afterSwap.selector, 0);
    }

    /**
     * @dev Returns the lower tick boundary for the hook's liquidity position.
     */
    function getTickLower() public view virtual returns (int24) {
        return TickMath.minUsableTick(_poolKey.tickSpacing);
    }

    /**
     * @dev Returns the upper tick boundary for the hook's liquidity position.
     */
    function getTickUpper() public view virtual returns (int24) {
        return TickMath.maxUsableTick(_poolKey.tickSpacing);
    }

    /**
     * @dev Calculates the balance delta required for adding a specific amount of liquidity.
     *
     * This function uses the current pool state and desired liquidity to determine
     * the exact amounts of both currencies needed to achieve the target liquidity.
     *
     * The liquidity parameter specifies the amount of liquidity to add.
     * The function returns a balance delta representing the required currency amounts.
     *
     * Requirements:
     * - The calculated amounts must be negative (assets flowing into the hook)
     */
    function _getDeltaForDepositedShares(uint128 liquidity) internal virtual returns (BalanceDelta delta) {
        int24 tickLower = getTickLower();
        int24 tickUpper = getTickUpper();

        (uint160 currentSqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(_poolKey.toId());

        delta =
            LiquidityMath.calculateDeltaForLiquidity(liquidity, currentTick, tickLower, tickUpper, currentSqrtPriceX96);

        if (delta.amount0() > 0 || delta.amount1() > 0) {
            revert InvalidAmounts();
        }
    }

    /**
     * @dev Calculates the balance delta for withdrawing a specific amount of shares.
     *
     * This function determines the proportional amounts of both currencies that should
     * be withdrawn based on the user's share balance relative to the total supply.
     *
     * The sharesAmount parameter specifies the amount of shares to withdraw.
     * The function returns a balance delta representing the currency amounts to withdraw.
     */
    function _getDeltaForWithdrawnShares(uint256 sharesAmount) internal virtual returns (BalanceDelta delta) {
        address yieldSource0 = getYieldSourceForCurrency(_poolKey.currency0);
        address yieldSource1 = getYieldSourceForCurrency(_poolKey.currency1);

        uint256 totalSharesCurrency0 = IERC4626(yieldSource0).maxWithdraw(address(this));
        uint256 totalSharesCurrency1 = IERC4626(yieldSource1).maxWithdraw(address(this));

        uint256 amount0 = FullMath.mulDiv(sharesAmount, totalSharesCurrency0, totalSupply());
        uint256 amount1 = FullMath.mulDiv(sharesAmount, totalSharesCurrency1, totalSupply());

        delta = toBalanceDelta(int256(amount0).toInt128(), int256(amount1).toInt128());
    }

    /**
     * @dev Returns the yield source address for a given currency.
     */
    function getYieldSourceForCurrency(Currency currency) public view virtual returns (address);

    /**
     * @dev Deposits a specified amount of a currency into its corresponding yield source.
     *
     * Note: For native ETH support, this function should be overridden to handle
     * the specific requirements of the yield source.
     */
    function _depositOnYieldSource(Currency currency, uint256 amount) internal virtual {
        // In this implementation with ERC4626, native currency is not supported
        if (currency.isAddressZero()) {
            revert InvalidCurrency();
        }
        address yieldSource = getYieldSourceForCurrency(currency);
        IERC20(Currency.unwrap(currency)).approve(yieldSource, amount);
        IERC4626(yieldSource).deposit(amount, address(this));
    }

    /**
     * @dev Withdraws a specified amount of a currency from its corresponding yield source.
     *
     * This function withdraws assets from the yield source and returns them to the hook
     * for further processing (e.g., transferring to users or adding to pool liquidity).
     */
    function _withdrawFromYieldSource(Currency currency, uint256 amount) internal virtual {
        address yieldSource = getYieldSourceForCurrency(currency);
        IERC4626(yieldSource).withdraw(amount, address(this), address(this));
    }

    /**
     * @dev Modifies the hook's liquidity position in the pool.
     * This function adds or removes liquidity from the hook's position using the pool manager.
     * Positive liquidityDelta adds liquidity, while negative removes it.
     */
    function _modifyLiquidity(int256 liquidityDelta) internal virtual returns (BalanceDelta delta) {
        (delta,) = poolManager.modifyLiquidity(
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

    /**
     * @dev Retrieves the current liquidity of the hook owned position in the pool based on its `key`
     */
    function _getHookLiquidity(PoolKey calldata key) internal virtual returns (uint128 liquidity) {
        bytes32 positionKey = Position.calculatePositionKey(address(this), getTickLower(), getTickUpper(), bytes32(0));
        liquidity = poolManager.getPositionLiquidity(key.toId(), positionKey);
    }

    /**
     * @dev Asserts the hook transient `currencyDelta` in a `currency` to be zeroed.
     * This function takes or settles the `currencyDelta` amount to the poolManager.
     */
    function _assertHookDelta(Currency currency) internal virtual {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (currencyDelta > 0) {
            currency.take(poolManager, address(this), currencyDelta.toUint256(), false);
            _depositOnYieldSource(currency, currencyDelta.toUint256());
        }
        if (currencyDelta < 0) {
            _withdrawFromYieldSource(currency, (-currencyDelta).toUint256());
            currency.settle(poolManager, address(this), (-currencyDelta).toUint256(), false);
        }
    }

    /**
     * @dev Calculates the amount of liquidity to be provided from yield source assets.
     * This function determines the amount of liquidity that that should be temporarily added to the pool
     * based on the current balance of assets in the yield sources, converted to their
     * underlying asset values.
     * Note: This calculation uses the current pool price to ensure the liquidity
     * can be properly distributed across the specified tick range.
     */
    // solhint-disable-next-line no-unused-parameter
    function _getLiquidityToUse(PoolKey calldata key, SwapParams calldata params)
        internal
        virtual
        returns (uint128 liquidity)
    {
        uint256 balanceYieldSource0 = IERC4626(getYieldSourceForCurrency(key.currency0)).balanceOf(address(this));
        uint256 balanceYieldSource1 = IERC4626(getYieldSourceForCurrency(key.currency1)).balanceOf(address(this));

        uint256 assetsCurrency0 =
            IERC4626(getYieldSourceForCurrency(key.currency0)).convertToAssets(balanceYieldSource0);
        uint256 assetsCurrency1 =
            IERC4626(getYieldSourceForCurrency(key.currency1)).convertToAssets(balanceYieldSource1);

        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(getTickLower()),
            TickMath.getSqrtPriceAtTick(getTickUpper()),
            assetsCurrency0,
            assetsCurrency1
        );
    }

    /**
     * @dev Returns the pool key for the hook.
     */
    function getPoolKey() public view returns (PoolKey memory) {
        return _poolKey;
    }

    /**
     * Set the hooks permissions, specifically `beforeInitialize`, `beforeSwap`, `afterSwap`.
     *
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
}
