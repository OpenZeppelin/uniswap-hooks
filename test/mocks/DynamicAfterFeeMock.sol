// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/fee/DynamicAfterFee.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract DynamicAfterFeeMock is DynamicAfterFee {
    constructor(IPoolManager _poolManager) DynamicAfterFee(_poolManager) {}

    function getTargetDelta(PoolId poolId) public view returns (BalanceDelta) {
        return _targetDeltas[poolId];
    }

    function setTargetDelta(PoolId poolId, BalanceDelta delta) public {
        _targetDeltas[poolId] = delta;
    }

    // Exclude from coverage report
    function test() public {}
}
