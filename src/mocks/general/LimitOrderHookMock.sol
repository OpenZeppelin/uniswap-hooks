// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Internal imports
import {CurrencySettler} from "../../utils/CurrencySettler.sol";
import {LimitOrderHook} from "../../general/LimitOrderHook.sol";
import {BaseHook} from "../../base/BaseHook.sol";

contract LimitOrderHookMock is LimitOrderHook {
    using CurrencySettler for *;

    /// @dev Tags the callback as this contract's own. `LimitOrderHook`'s callbacks encode `0x20` first.
    uint256 private constant INTERNAL_SWAP_TAG = type(uint256).max;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Swaps `amount` toward `targetTick` from inside this hook's own unlock callback, which the pool
     * does not report. Fills the orders it crossed when `fillCrossed`, and models the subclass that forgets
     * to otherwise.
     */
    function internalSwap(PoolKey calldata key, int24 targetTick, uint256 amount, bool fillCrossed) external {
        poolManager.unlock(abi.encode(INTERNAL_SWAP_TAG, key, targetTick, amount, fillCrossed));
    }

    function unlockCallback(bytes calldata rawData) public virtual override onlyPoolManager returns (bytes memory) {
        if (abi.decode(rawData[:32], (uint256)) != INTERNAL_SWAP_TAG) return super.unlockCallback(rawData);

        (, PoolKey memory key, int24 targetTick, uint256 amount, bool fillCrossed) =
            abi.decode(rawData, (uint256, PoolKey, int24, uint256, bool));

        SwapParams memory params = SwapParams({
            zeroForOne: targetTick < _getCurrentTick(key.toId()),
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
        });

        BalanceDelta delta = poolManager.swap(key, params, "");

        if (fillCrossed) _fillCrossedOrders(key, params.zeroForOne);

        _settle(key, delta);

        return "";
    }

    function _settle(PoolKey memory key, BalanceDelta delta) private {
        if (delta.amount0() < 0) {
            key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
        }
        if (delta.amount0() > 0) {
            key.currency0.take(poolManager, address(this), uint256(uint128(delta.amount0())), false);
        }
        if (delta.amount1() > 0) {
            key.currency1.take(poolManager, address(this), uint256(uint128(delta.amount1())), false);
        }
    }

    // exclude from coverage report
    function test() public {}
}
