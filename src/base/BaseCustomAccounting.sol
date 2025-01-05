// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/base/BaseCustomAccounting.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @dev Base implementation for custom accounting and hook-owned liquidity, which must be deposited
 * directly via the hook.
 *
 * NOTE: This base hook is designed to work with a single pool key. If you want to use the same custom
 * accounting hook for two pools, you must have two storage instances of this contract and initialize
 * them via the `PoolManager` with their respective pool keys.
 *
 * NOTICE: TODO: add support for fees, consider that liquidity is implemented with the hook as the sole
 * owner.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseCustomAccounting is BaseHook {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    error ExpiredPastDeadline();
    error PoolNotInitialized();
    error TooMuchSlippage();

    struct AddLiquidityParams {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
    }

    struct RemoveLiquidityParams {
        uint256 liquidity;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
    }

    struct CallbackData {
        address sender;
        IPoolManager.ModifyLiquidityParams params;
    }

    PoolKey public poolKey;

    /**
     * @dev Ensure the deadline of a liquidity modification request is not expired.
     */
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    /**
     * @dev Set the pool `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @notice Adds liquidity to the hook's pool.
     *
     * To cover all possible scenarios, `msg.sender` should have already given the hook an allowance
     * of at least amount0Desired/amount1Desired on token0/token1.
     *
     * Always adds assets at the ideal ratio, according to the price when the transaction is executed.
     */
    function addLiquidity(AddLiquidityParams calldata params)
        external
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        (bytes memory modifyParams, uint256 liquidity) = _getAddLiquidity(sqrtPriceX96, params);

        delta = _modifyLiquidity(modifyParams);

        _mint(params, delta, liquidity);

        if (uint128(-delta.amount0()) < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    /**
     * @notice Removes liquidity from the hook's pool.
     *
     * `msg.sender` should have already given the hook allowance of at least liquidity on the pool.
     */
    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        (bytes memory modifyParams, uint256 liquidity) = _getRemoveLiquidity(params);

        delta = _modifyLiquidity(modifyParams);

        _burn(params, delta, liquidity);
    }

    /**
     * @dev Call the Uniswap `PoolManager` to unlock and call back the hook.
     */
    function _modifyLiquidity(bytes memory params) internal virtual returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(
                abi.encode(CallbackData(msg.sender, abi.decode(params, (IPoolManager.ModifyLiquidityParams))))
            ),
            (BalanceDelta)
        );
    }

    /**
     * @dev Callback when pool liquidity is modified, either adding or removing.
     */
    function _unlockCallback(bytes calldata rawData) internal virtual override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        // Apply liquidity modification parameters
        (delta,) = poolManager.modifyLiquidity(poolKey, data.params, "");

        // If liquidity delta is negative, remove liquidity from the pool. Otherwise, add liquidity to the pool.
        if (data.params.liquidityDelta < 0) {
            // Get tokens from the pool
            poolKey.currency0.take(poolManager, data.sender, uint256(int256(delta.amount0())), false);
            poolKey.currency1.take(poolManager, data.sender, uint256(int256(delta.amount1())), false);
        } else {
            // Send tokens to the pool to net out settlement
            poolKey.currency0.settle(poolManager, data.sender, uint256(int256(-delta.amount0())), false);
            poolKey.currency1.settle(poolManager, data.sender, uint256(int256(-delta.amount1())), false);
        }
        return abi.encode(delta);
    }

    /**
     * @dev Initialize the hook's pool key. The stored key should act immutably so that
     * it can safely be used across the hook's functions.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        override
        onlyPoolManager
        returns (bytes4)
    {
        // Store the pool key to be used in other functions
        poolKey = key;
        return this.beforeInitialize.selector;
    }

    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 liquidity);

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 liquidity);

    function _mint(AddLiquidityParams memory params, BalanceDelta delta, uint256 liquidity) internal virtual;

    function _burn(RemoveLiquidityParams memory params, BalanceDelta delta, uint256 liquidity) internal virtual;

    /**
     * @dev Set the hook permissions, specifically `beforeSwap` and `beforeSwapReturnDelta`.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
