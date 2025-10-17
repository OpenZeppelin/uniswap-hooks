// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/fee/BaseDynamicFee.sol)

pragma solidity ^0.8.26;

// External imports
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
// Internal imports
import {BaseHook} from "../base/BaseHook.sol";

/**
 * @dev Base implementation to apply a dynamic fee via the `PoolManager`'s `updateDynamicLPFee` function.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseDynamicFee is BaseHook {
    using LPFeeLibrary for uint24;

    /**
     * @dev The hook was attempted to be initialized with a non-dynamic fee.
     */
    error NotDynamicFee();

    /**
     * @dev Returns a fee, denominated in hundredths of a bip, to be applied to the pool after it is initialized.
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
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        poolManager().updateDynamicLPFee(key, _getFee(key));
        return this.afterInitialize.selector;
    }

    /**
     * @dev Updates the dynamic LP fee for the given pool
     *
     * NOTE: It can be called internally at any point in the pool's lifecycle to update the fee
     * given the current market conditions. Alternatively, it can be wrapped and exposed publicly
     * to be externally called by an authorized party. If exposed, it must be properly protected
     * and access control is recommended.
     *
     * @param key The pool key to update the dynamic LP fee for.
     */
    function _poke(PoolKey calldata key) internal virtual {
        poolManager().updateDynamicLPFee(key, _getFee(key));
    }

    /**
     * @dev Set the hook permissions, specifically `afterInitialize`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
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
