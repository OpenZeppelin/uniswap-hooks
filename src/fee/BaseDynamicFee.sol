// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/fee/BaseDynamicFee.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/**
 * @dev Base implementation to apply a dynamic fee via the PoolManager's {updateDynamicLPFee} function.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseDynamicFee is BaseHook {
    /**
     * @dev Set the pool manager.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Returns a fee, denominated in hundredths of a percent, to be applied to the pool after it is initialized.
     */
    function _getFee(PoolKey calldata key) internal virtual returns (uint24);

    /**
     * @dev Set the fee after the pool is initialized.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        poolManager.updateDynamicLPFee(key, _getFee(key));
        return this.afterInitialize.selector;
    }

    /**
     * @notice Updates the dynamic LP fee for the given pool.
     */
    function poke(PoolKey calldata key) external virtual {
        poolManager.updateDynamicLPFee(key, _getFee(key));
    }

    /**
     * @dev Set the hook permissions, specifically {afterInitialize}.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
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
