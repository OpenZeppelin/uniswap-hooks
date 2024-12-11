// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/fee/BaseOverrideFee.sol";

contract BaseOverrideFeeMock is BaseOverrideFee {
    constructor(IPoolManager _poolManager) BaseOverrideFee(_poolManager) {}

    function _getFee(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (uint24)
    {
        return 50000;
    }

    // Exclude from coverage report
    function test() public {}
}
