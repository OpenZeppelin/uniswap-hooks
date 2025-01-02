// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/base/BaseNoOp.sol";

contract BaseNoOpMock is BaseNoOp {
    constructor(IPoolManager _poolManager) BaseNoOp(_poolManager) {}

    // Exclude from coverage report
    function test() public {}
}
