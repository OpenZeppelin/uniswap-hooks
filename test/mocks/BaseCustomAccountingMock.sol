// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BaseCustomAccounting} from "src/base/BaseCustomAccounting.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract BaseCustomAccountingMock is BaseCustomAccounting {
    uint24 public rate;

    constructor(IPoolManager _poolManager) BaseCustomAccounting(_poolManager, "Mock", "MOCK") {}

    function setRate(uint24 _rate) public {
        rate = _rate;
    }

    function _getAmount(uint256 amountIn, Currency, Currency, bool, bool)
        internal
        view
        override
        returns (uint256 amount)
    {
        // Apply rate on `amountIn`. For example, if rate is 5000, then the output amount will be 50% of `amountIn`.
        amount = (amountIn * rate) / 10000;
    }

    // Exclude from coverage report
    function test() public {}
}
