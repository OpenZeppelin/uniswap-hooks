// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// Internal imports
import {BaseDynamicAfterFee} from "../../src/fee/BaseDynamicAfterFee.sol";
import {CurrencySettler} from "../../src/utils/CurrencySettler.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

contract BaseDynamicAfterFeeMock is BaseDynamicAfterFee {
    using CurrencySettler for Currency;

    uint256 public targetUnspecifiedAmount;
    bool public applyTarget;

    constructor(IPoolManager _poolManager) BaseDynamicAfterFee(_poolManager) {}

    function setMockTargetUnspecifiedAmount(uint256 amount, bool active) public {
        targetUnspecifiedAmount = amount;
        applyTarget = active;
    }

    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        uint256,
        uint256 feeAmount
    ) internal override {
        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? (key.currency1) : (key.currency0);

        // Burn ERC-6909 and take underlying tokens
        unspecified.settle(poolManager, address(this), feeAmount, true);
        unspecified.take(poolManager, address(this), feeAmount, false);
    }

    function _getTargetUnspecified(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (uint256, bool)
    {
        return (targetUnspecifiedAmount, applyTarget);
    }

    receive() external payable {}

    // Exclude from coverage report
    function test() public {}
}
