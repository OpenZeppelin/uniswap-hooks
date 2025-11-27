// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// Internal imports
import {BaseAsyncSwap} from "../../src/base/BaseAsyncSwap.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

contract BaseAsyncSwapMock is BaseAsyncSwap {
    constructor(IPoolManager _poolManager) BaseAsyncSwap(_poolManager) {}

    // Exclude from coverage report
    function test() public {}
}
