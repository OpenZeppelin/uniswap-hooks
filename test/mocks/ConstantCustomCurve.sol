// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {BaseCustomCurve} from "src/base/BaseCustomCurve.sol";

contract ConstantSumCurve is BaseCustomCurve {
    using CurrencySettler for Currency;

    constructor(IPoolManager _manager) BaseCustomCurve(_manager) {}

    function _getAmountOutFromExactInput(uint256 amountIn, Currency, Currency, bool)
        internal
        pure
        override
        returns (uint256 amountOut)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountOut = amountIn;
    }

    function _getAmountInForExactOutput(uint256 amountOut, Currency, Currency, bool)
        internal
        pure
        override
        returns (uint256 amountIn)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountIn = amountOut;
    }

    /// @notice Add liquidity through the hook
    /// @dev Not production-ready, only serves an example of hook-owned liquidity
    function addLiquidity(PoolKey calldata key, uint256 amount0, uint256 amount1) external {
        poolManager.unlock(
            abi.encodeCall(this.handleAddLiquidity, (key.currency0, key.currency1, amount0, amount1, msg.sender))
        );
    }

    /// @dev Handle liquidity addition by taking tokens from the sender and claiming ERC6909 to the hook address
    function handleAddLiquidity(
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address sender
    ) external selfOnly returns (bytes memory) {
        currency0.settle(poolManager, sender, amount0, false);
        currency0.take(poolManager, address(this), amount0, true);

        currency1.settle(poolManager, sender, amount1, false);
        currency1.take(poolManager, address(this), amount1, true);

        return abi.encode(amount0, amount1);
    }

    // Exclude from coverage report
    function test() public {}
}
