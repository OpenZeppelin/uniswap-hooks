// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/fee/DynamicAfterFee.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/**
 * @dev Base implementation for dynamic fees applied after swaps.
 *
 * In order to use this hook, the inheriting contract must define a target delta for a swap before
 * the {afterSwap} function is called. Refer to the {AntiSandwichHook} contract as an example
 * implementation of this pattern.
 *
 * NOTE: This hook only supports exact-input swaps. For exact-output swaps, the hook will not apply
 * the target delta.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract DynamicAfterFee is BaseHook {
    mapping(PoolId => BalanceDelta) internal _targetDeltas;

    /**
     * @dev Set the pool manager.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Calculate the target delta and apply the fee so that the returned delta matches.
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal virtual override returns (bytes4, int128) {
        if (params.amountSpecified < 0) {
            PoolId poolId = key.toId();
            BalanceDelta targetDelta = _targetDeltas[poolId];
            int128 feeAmount = 0;

            if (BalanceDelta.unwrap(targetDelta) != 0) {
                // Reset storage target delta to 0 and use one stored in memory
                _targetDeltas[poolId] = BalanceDelta.wrap(0);

                if (delta.amount0() == targetDelta.amount0() && delta.amount1() > targetDelta.amount1()) {
                    feeAmount = delta.amount1() - targetDelta.amount1();
                    poolManager.donate(key, 0, uint256(uint128(feeAmount)), "");
                }

                // Apply target delta to only exact-input swaps
                if (delta.amount1() == targetDelta.amount1() && delta.amount0() > targetDelta.amount0()) {
                    feeAmount = delta.amount0() - targetDelta.amount0();
                    // feeAmount is positive and int128, so we can safely cast to uint128 and then to uint256
                    poolManager.donate(key, uint256(uint128(feeAmount)), 0, "");
                }
            }

            return (this.afterSwap.selector, feeAmount);
        } else {
            return (this.afterSwap.selector, 0);
        }
    }

    /**
     * @dev Set the hook permissions, specifically {afterSwap} and {afterSwapReturnDelta}.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
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
