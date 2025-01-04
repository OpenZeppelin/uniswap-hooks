// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BaseCustomAccounting} from "src/base/BaseCustomAccounting.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract BaseCustomAccountingMock is BaseCustomAccounting {
    constructor(IPoolManager _poolManager) BaseCustomAccounting(_poolManager, "Mock", "MOCK") {}

    // Exclude from coverage report
    function test() public {}
}
