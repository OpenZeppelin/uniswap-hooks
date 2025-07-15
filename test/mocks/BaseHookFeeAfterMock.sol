// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHookFeeAfter} from "src/fee/BaseHookFeeAfter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract BaseHookFeeAfterMock is BaseHookFeeAfter {

    uint128 private _unspecifiedHookFee;

    constructor(IPoolManager _poolManager) BaseHookFeeAfter(_poolManager) {}

    function setHookFee(uint128 unspecifiedFee) external {
        _unspecifiedHookFee = unspecifiedFee;
    }

    function _getAfterSwapHookFee(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal view override returns (uint128 unspecifiedFee) {
        return _unspecifiedHookFee;
    }
}