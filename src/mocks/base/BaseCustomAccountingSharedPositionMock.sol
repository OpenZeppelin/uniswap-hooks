// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// Internal imports
import {BaseCustomAccountingMock} from "./BaseCustomAccountingMock.sol";

contract BaseCustomAccountingSharedPositionMock is BaseCustomAccountingMock {
    constructor(IPoolManager _poolManager) BaseCustomAccountingMock(_poolManager) {}

    function _getPositionSalt(address, bytes32 salt) internal view override returns (bytes32) {
        return salt;
    }

    // Exclude from coverage report
    function test() public override {}
}
