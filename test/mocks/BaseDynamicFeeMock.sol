// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/fee/BaseDynamicFee.sol";

contract BaseDynamicFeeMock is BaseDynamicFee {
    constructor(IPoolManager _poolManager) BaseDynamicFee(_poolManager) {}

    function _getFee(PoolKey calldata) internal pure override returns (uint24) {
        return 50000;
    }

    // Exclude from coverage report
    function test() public {}
}
