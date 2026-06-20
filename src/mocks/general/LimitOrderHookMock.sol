// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
// Internal imports
import {LimitOrderHook} from "../../general/LimitOrderHook.sol";
import {BaseHook} from "../../base/BaseHook.sol";

contract LimitOrderHookMock is LimitOrderHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @dev Test helper: force a (possibly stale) `tickLowerLast`, mimicking a subclass internal swap
    /// that Uniswap V4 excludes from `afterSwap` (self-call protection).
    function setTickLowerLast(PoolId poolId, int24 tickLower) external {
        _setTickLowerLast(poolId, tickLower);
    }

    // exclude from coverage report
    function test() public {}
}
