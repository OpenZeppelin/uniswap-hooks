// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// Internal imports
import {LiquidityPenaltyHook} from "../../general/LiquidityPenaltyHook.sol";
import {BaseHook} from "../../base/BaseHook.sol";

contract LiquidityPenaltyHookMock is LiquidityPenaltyHook {
    uint48 private immutable _blockNumberOffset;

    constructor(IPoolManager _poolManager, uint48 blockNumberOffset_) BaseHook(_poolManager) {
        if (blockNumberOffset_ < MIN_BLOCK_NUMBER_OFFSET) revert BlockNumberOffsetTooLow();
        _blockNumberOffset = blockNumberOffset_;
    }

    /// @dev Overrides the default offset with the constructor-provided value (configurable for tests).
    function getBlockNumberOffset() public view override returns (uint48) {
        return _blockNumberOffset;
    }

    // exclude from coverage report
    function test() public {}
}
