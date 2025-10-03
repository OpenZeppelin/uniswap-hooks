// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// Internal imports
import {BaseDynamicAfterFee} from "../fee/BaseDynamicAfterFee.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";

contract BaseDynamicAfterFeeMock is BaseDynamicAfterFee {
    using CurrencySettler for Currency;

    uint256 private _mockTargetUnspecifiedAmount;
    bool private _mockApplyTarget;

    function setMockTargetUnspecifiedAmount(uint256 amount, bool active) public {
        _mockTargetUnspecifiedAmount = amount;
        _mockApplyTarget = active;
    }

    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        uint256,
        uint256 feeAmount
    ) internal override {
        IPoolManager poolManager = poolManager();
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
        return (_mockTargetUnspecifiedAmount, _mockApplyTarget);
    }

    receive() external payable {}

    // Exclude from coverage report
    function test() public {}
}
