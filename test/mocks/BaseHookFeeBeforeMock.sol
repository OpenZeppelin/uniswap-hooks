// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHookFeeBefore} from "src/fee/BaseHookFeeBefore.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract BaseHookFeeBeforeMock is BaseHookFeeBefore {

    uint128 private _specifiedHookFee;
    uint128 private _unspecifiedHookFee;

    constructor(IPoolManager _poolManager) BaseHookFeeBefore(_poolManager) {}

    function setHookFee(uint128 specifiedFee, uint128 unspecifiedFee) external {
        _specifiedHookFee = specifiedFee;
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