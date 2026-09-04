// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Internal imports
import {BaseCustomCurveMock} from "./BaseCustomCurveMock.sol";

/**
 * @title BaseCustomCurveFeeMock
 * @dev Constant-sum {BaseCustomCurve} that charges a swap fee for LPs. The fee reduces the output on exact input
 * swaps and raises the input on exact output swaps, so it accrues in the unspecified currency on both.
 */
contract BaseCustomCurveFeeMock is BaseCustomCurveMock {
    /// @notice The swap fee charged for LPs, defined in basis points (up to 10_000)
    uint256 private _swapFeeBps;

    constructor(IPoolManager _poolManager) BaseCustomCurveMock(_poolManager) {}

    function setSwapFee(uint256 feeBps) external {
        _swapFeeBps = feeBps;
    }

    /// @dev The fee charged on a swap of `amountSpecified`, denominated in the unspecified currency.
    function swapFee(int256 amountSpecified) public view returns (uint256) {
        uint256 specifiedAmount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        return specifiedAmount * _swapFeeBps / 10_000;
    }

    function _getUnspecifiedAmount(SwapParams calldata params)
        internal
        virtual
        override
        returns (uint256 unspecifiedAmount)
    {
        unspecifiedAmount = super._getUnspecifiedAmount(params);
        uint256 fee = swapFee(params.amountSpecified);
        return params.amountSpecified < 0 ? unspecifiedAmount - fee : unspecifiedAmount + fee;
    }

    function _getSwapFeeAmount(SwapParams calldata params, uint256)
        internal
        virtual
        override
        returns (uint256 swapFeeAmount)
    {
        return swapFee(params.amountSpecified);
    }
}
