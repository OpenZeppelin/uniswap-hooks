// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// Internal imports
import {BaseDynamicFee} from "../../src/fee/BaseDynamicFee.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

contract BaseDynamicFeeMock is BaseDynamicFee {
    uint24 public fee;

    constructor(IPoolManager _poolManager) BaseDynamicFee(_poolManager) {}

    function _getFee(PoolKey calldata) internal view override returns (uint24) {
        return fee;
    }

    function setFee(uint24 _fee) public {
        fee = _fee;
    }

    // Exclude from coverage report
    function test() public {}
}
