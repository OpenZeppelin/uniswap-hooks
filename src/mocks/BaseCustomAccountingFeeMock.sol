// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// Internal imports
import {CurrencySettler} from "../utils/CurrencySettler.sol";
import {BaseCustomAccountingMock} from "../mocks/BaseCustomAccountingMock.sol";

contract BaseCustomAccountingFeeMock is BaseCustomAccountingMock {
    using CurrencySettler for Currency;

    /// @notice The fee to keep from accrued fees, defined in basis points (up to 10_000)
    uint256 private _feesAccruedFeeBps;

    function setFee(uint256 feeBps) external {
        _feesAccruedFeeBps = feeBps;
    }

    function _handleAccruedFees(CallbackData memory data, BalanceDelta callerDelta, BalanceDelta feesAccrued)
        internal
        override
    {
        PoolKey memory key = poolKey();
        IPoolManager poolManager = poolManager();

        uint256 feesAccruedFeeBps = _feesAccruedFeeBps;

        // Fetch fees from the pool
        key.currency0.take(poolManager, address(this), uint256(int256(feesAccrued.amount0())), false);
        key.currency1.take(poolManager, address(this), uint256(int256(feesAccrued.amount1())), false);

        uint256 fee0 = uint256(int256(feesAccrued.amount0())) * feesAccruedFeeBps / 10_000;
        uint256 fee1 = uint256(int256(feesAccrued.amount1())) * feesAccruedFeeBps / 10_000;

        // Send remaining to the sender
        key.currency0.transfer(data.sender, uint256(int256(feesAccrued.amount0())) - fee0);
        key.currency1.transfer(data.sender, uint256(int256(feesAccrued.amount1())) - fee1);
    }

    receive() external payable {}

    // Exclude from coverage report
    function test() public override {}
}
