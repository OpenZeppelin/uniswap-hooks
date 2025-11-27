// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// Internal imports
import {BaseOverrideFee} from "../../src/fee/BaseOverrideFee.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

contract BaseOverrideFeeMock is BaseOverrideFee {
    uint24 public fee;

    constructor(IPoolManager _poolManager) BaseOverrideFee(_poolManager) {}

    function _getFee(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return fee;
    }

    function setFee(uint24 _fee) public {
        fee = _fee;
    }

    // Exclude from coverage report
    function test() public {}
}
