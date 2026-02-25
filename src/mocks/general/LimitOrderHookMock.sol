// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// Internal imports
import {LimitOrderHook} from "../../general/LimitOrderHook.sol";
import {BaseHook} from "../../base/BaseHook.sol";
import {OrderIdLibrary} from "../../general/LimitOrderHook.sol";

contract LimitOrderHookMock is LimitOrderHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // exclude from coverage report
    function test() public {}
}
