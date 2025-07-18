// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.1) (src/general/LiquidityPenaltyHook.sol)

pragma solidity ^0.8.24;

// Internal imports
import {BaseHook} from "../base/BaseHook.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

// External imports
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

abstract contract ReHypothecationHook is BaseHook {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for *;

    uint256 public totalShares;
    mapping(address => uint256) private shares;

    error ZeroLiquidity();

    error AlreadyInitialized();

    error PoolKeyNotInitialized();

    error InvalidMsgValue();
    error RefundFailed();

    event ReHypothecatedLiquidityAdded(address indexed sender, uint256 sharesAmount, uint256 amount0, uint256 amount1);

    PoolKey public poolKey;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function addReHypothecatedLiquidity(uint256 sharesAmount) external payable {
        if (poolKey.currency1.isAddressZero()) revert PoolKeyNotInitialized();

        if (sharesAmount == 0) revert ZeroLiquidity();

        (uint256 amount0, uint256 amount1) = _getAmountsForDepositedShares(sharesAmount);

        if (poolKey.currency0.isAddressZero()) {
            if (msg.value < amount0) revert InvalidMsgValue();
            uint256 refund = msg.value - amount0;
            if (refund > 0) {
                (bool success,) = msg.sender.call{value: refund}("");
                if (!success) revert RefundFailed();
            }
        } else {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        }
        IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1);

        _depositOnYieldSource(poolKey.currency0, amount0);
        _depositOnYieldSource(poolKey.currency1, amount1);

        emit ReHypothecatedLiquidityAdded(msg.sender, sharesAmount, amount0, amount1);
    }

    function removeReHypothecatedLiquidity(address owner) external {
        uint256 sharesAmount = shares[owner];
        if (sharesAmount == 0) revert ZeroLiquidity();

        (uint256 amount0, uint256 amount1) = _getAmountsForWithdrawnShares(sharesAmount);

        _decreaseShares(owner, sharesAmount);

        _withdrawFromYieldSource(poolKey.currency0, amount0);
        _withdrawFromYieldSource(poolKey.currency1, amount1);

        poolKey.currency0.transfer(owner, amount0);
        poolKey.currency1.transfer(owner, amount1);

        emit ReHypothecatedLiquidityRemoved(owner, sharesAmount, amount0, amount1);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        int256 liquidityToUse = _getLiquidityToUse(key, params);

        if (liquidityToUse > 0) {
            _modifyLiquidity(liquidityToUse);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev Initialize the hook's pool key. The stored key should act immutably so that
     * it can safely be used across the hook's functions.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Check if the pool key is already initialized
        if (address(poolKey.hooks) != address(0)) revert AlreadyInitialized();

        // Store the pool key to be used in other functions
        poolKey = key;
        return this.beforeInitialize.selector;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        uint128 liquidity = _getHookLiquidity(key);
        if (liquidity == 0) {
            return (this.afterSwap.selector, 0);
        }

        _modifyLiquidity(-liquidity.toInt256());

        _assertHookDelta(key.currency0);
        _assertHookDelta(key.currency1);

        return (this.afterSwap.selector, 0);
    }

    function getTickLower() public view virtual returns (int24) {
        return TickMath.minUsableTick(poolKey.tickSpacing);
    }

    function getTickUpper() public view virtual returns (int24) {
        return TickMath.maxUsableTick(poolKey.tickSpacing);
    }

    function _getAmountsForDepositedShares(uint256 sharesAmount)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1);

    function _getAmountsForWithdrawnShares(uint256 sharesAmount)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1);

    function _depositOnYieldSource(Currency currency, uint256 amount) internal virtual;

    function _withdrawFromYieldSource(Currency currency, uint256 amount) internal virtual;

    function _modifyLiquidity(int256 liquidityDelta) internal virtual returns (BalanceDelta delta) {
        (delta,) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: getTickLower(),
                tickUpper: getTickUpper(),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _getHookLiquidity(PoolKey calldata key) internal virtual returns (uint128 liquidity) {
        bytes32 positionKey = Position.calculatePositionKey(address(this), getTickLower(), getTickUpper(), bytes32(0));
        liquidity = poolManager.getPositionLiquidity(key.toId(), positionKey);
    }

    function _assertHookDelta(Currency currency) internal virtual {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (currencyDelta > 0) {
            currency.take(poolManager, address(this), currencyDelta.toUint256(), false);
            _depositOnYieldSource(currency, currencyDelta.toUint256());
        }
        if (currencyDelta < 0) {
            currency.settle(poolManager, address(this), (-currencyDelta).toUint256(), false);
            _withdrawFromYieldSource(currency, (-currencyDelta).toUint256());
        }
    }

    function _increaseShares(address owner, uint256 sharesAmount) internal virtual {
        totalShares += sharesAmount;
        shares[owner] += sharesAmount;
    }

    function _decreaseShares(address owner, uint256 sharesAmount) internal virtual {
        totalShares -= sharesAmount;
        shares[owner] -= sharesAmount;
    }

    function _getLiquidityToUse(PoolKey calldata key, SwapParams calldata params)
        internal
        virtual
        returns (int256 liquidity);

    /**
     * Set the hooks permissions, specifically `afterAddLiquidity`, `afterRemoveLiquidity` and `afterRemoveLiquidityReturnDelta`.
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
