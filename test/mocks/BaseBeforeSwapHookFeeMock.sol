// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseBeforeSwapHookFee} from "src/fee/BaseBeforeSwapHookFee.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "src/base/BaseHook.sol";

contract BaseBeforeSwapHookFeeMock is BaseBeforeSwapHookFee {

    uint128 private _specifiedHookFee;
    uint128 private _unspecifiedHookFee;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function setMockHookFee(uint128 specifiedFee, uint128 unspecifiedFee) external {
        _specifiedHookFee = specifiedFee;
        _unspecifiedHookFee = unspecifiedFee;
    }

    /*
    * @dev @inheritdoc BaseBeforeSwapHookFee
    */
    function _getBeforeSwapHookFee(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal view override returns (uint128 specifiedFee, uint128 unspecifiedFee) {
        return (_specifiedHookFee, _unspecifiedHookFee);
    }
}