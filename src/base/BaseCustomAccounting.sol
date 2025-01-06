// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/base/BaseCustomAccounting.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {CurrencySettler} from "src/lib/CurrencySettler.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @dev Base implementation for custom accounting and hook-owned liquidity.
 *
 * To enable hook-owned liquidity, tokens must be deposited via the hook to allow control and flexibility
 * over the liquidity. The implementation inheriting this hook must implement the respective functions
 * to calculate the liquidity modification parameters and the amount of liquidity units to mint or burn.
 *
 * Aditionally, the implementator must consider that the hook is the sole owner of the liquidity and
 * manage fees over liquidity units accordingly.
 *
 * NOTE: This base hook is designed to work with a single pool key. If you want to use the same custom
 * accounting hook for multiple pools, you must have multiple storage instances of this contract and
 * initialize them via the `PoolManager` with their respective pool keys.
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

    /**
     * @dev An liquidity modification order was attempted to be executed after the deadline.
     */
    error ExpiredPastDeadline();

    /**
     * @dev Pool was not initialized.
     */
    error PoolNotInitialized();

    /**
     * @dev Liquidity modification delta resulted in too much slippage.
     */
    error TooMuchSlippage();

    /**
     * @dev Liquidity was attempted to be added or removed via the `PoolManager` instead of the hook.
     */
    error LiquidityOnlyViaHook();

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

    /**
     * @notice The hook's pool key.
     */
    PoolKey public poolKey;

    /**
     * @dev Ensure the deadline of a liquidity modification request is not expired.
     *
     * @param deadline Deadline of the request, passed in by the caller.
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
     * @dev To cover all possible scenarios, `msg.sender` should have already given the hook an allowance
     * of at least amount0Desired/amount1Desired on token0/token1. Always adds assets at the ideal ratio,
     * according to the price when the transaction is executed.
     *
     * @param params The parameters for the liquidity addition.
     * @return delta The balance delta of the liquidity addition from the `PoolManager`.
     */
    function addLiquidity(AddLiquidityParams calldata params)
        external
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Get the liquidity modification parameters and the amount of liquidity units to mint
        (bytes memory modifyParams, uint256 liquidity) = _getAddLiquidity(sqrtPriceX96, params);

        // Apply the liquidity modification
        delta = _modifyLiquidity(modifyParams);

        // Mint the liquidity units to the sender
        _mint(params, delta, liquidity);

        // Check for slippage
        if (uint128(-delta.amount0()) < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    /**
     * @notice Removes liquidity from the hook's pool.
     *
     * @dev `msg.sender` should have already given the hook allowance of at least liquidity on the pool.
     *
     * @param params The parameters for the liquidity removal.
     * @return delta The balance delta of the liquidity removal from the `PoolManager`.
     */
    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Get the liquidity modification parameters and the amount of liquidity units to burn
        (bytes memory modifyParams, uint256 liquidity) = _getRemoveLiquidity(params);

        // Apply the liquidity modification
        delta = _modifyLiquidity(modifyParams);

        // Burn the liquidity units from the sender
        _burn(params, delta, liquidity);
    }

    /**
     * @dev Calls the `PoolManager` to unlock and call back the hook's `_unlockCallback` function.
     *
     * @param params The encoded parameters for the liquidity modification based on the `ModifyLiquidityParams` struct.
     * @return delta The balance delta of the liquidity modification from the `PoolManager`.
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
     * @dev Callback from the `PoolManager` when liquidity is modified, either adding or removing.
     *
     * NOTE: This function assumes that both delta amounts are negative when removing liquidity, and positive
     * when adding liquidity. In case it's needed to support a negative and positive delta for a single
     * liquidity modification, this function should be overridden or the amount values adjusted
     * accordingly.
     *
     * @param rawData The encoded `CallbackData` struct.
     * @return delta The balance delta of the liquidity modification from the `PoolManager`.
     */
    function _unlockCallback(bytes calldata rawData) internal virtual override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        // Apply liquidity modification parameters
        (delta,) = poolManager.modifyLiquidity(poolKey, data.params, "");

        // If liquidity delta is negative, remove liquidity from the pool. Otherwise, add liquidity to the pool.
        if (data.params.liquidityDelta < 0) {
            // Get tokens from the pool and send to the sender
            poolKey.currency0.take(poolManager, data.sender, uint256(int256(delta.amount0())), false);
            poolKey.currency1.take(poolManager, data.sender, uint256(int256(delta.amount1())), false);
        } else {
            // Send tokens from the sender to the pool
            poolKey.currency0.settle(poolManager, data.sender, uint256(int256(-delta.amount0())), false);
            poolKey.currency1.settle(poolManager, data.sender, uint256(int256(-delta.amount1())), false);
        }
        return abi.encode(delta);
    }

    /**
     * @dev Initialize the hook's pool key. The stored key should act immutably so that
     * it can safely be used across the hook's functions.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Store the pool key to be used in other functions
        poolKey = key;
        return this.beforeInitialize.selector;
    }

    /**
     * @dev Revert when liquidity is attempted to be added via the `PoolManager`.
     */
    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    /**
     * @dev Revert when liquidity is attempted to be removed via the `PoolManager`.
     */
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        revert LiquidityOnlyViaHook();
    }

    /**
     * @dev Get the liquidity modification to apply for a given liquidity addition,
     * and the amount of liquidity units would be minted to the sender.
     *
     * @param sqrtPriceX96 The current square root price of the pool.
     * @param params The parameters for the liquidity addition.
     * @return modify The encoded parameters for the liquidity addition, which must follow the
     * `ModifyLiquidityParams` struct in the default implementation.
     * @return liquidity The liquidity units to mint.
     */
    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 liquidity);

    /**
     * @dev Get the liquidity modification to apply for a given liquidity removal,
     * and the amount of liquidity units would be burned from the sender.
     *
     * @param params The parameters for the liquidity removal.
     * @return modify The encoded parameters for the liquidity removal, which must follow the
     * `ModifyLiquidityParams` struct in the default implementation.
     * @return liquidity The liquidity units to burn.
     */
    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 liquidity);

    /**
     * @dev Mint liquidity units to the sender.
     *
     * @param params The parameters for the liquidity addition.
     * @param delta The balance delta of the liquidity addition from the `PoolManager`.
     * @param liquidity The liquidity units to mint.
     */
    function _mint(AddLiquidityParams memory params, BalanceDelta delta, uint256 liquidity) internal virtual;

    /**
     * @dev Burn liquidity units from the sender.
     *
     * @param params The parameters for the liquidity removal.
     * @param delta The balance delta of the liquidity removal from the `PoolManager`.
     * @param liquidity The liquidity units to burn.
     */
    function _burn(RemoveLiquidityParams memory params, BalanceDelta delta, uint256 liquidity) internal virtual;

    /**
     * @dev Set the hook permissions, specifically `beforeInitialize`.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
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
