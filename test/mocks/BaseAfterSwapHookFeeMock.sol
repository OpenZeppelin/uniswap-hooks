// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseAfterSwapHookFee} from "src/fee/BaseAfterSwapHookFee.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "src/base/BaseHook.sol";

contract BaseHookFeeAfterMock is BaseAfterSwapHookFee {
    uint128 private _unspecifiedHookFee;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function setMockHookFee(uint128 unspecifiedFee) external {
        _unspecifiedHookFee = unspecifiedFee;
    }

    /*
    * @dev @inheritdoc BaseAfterSwapHookFee
    */
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
