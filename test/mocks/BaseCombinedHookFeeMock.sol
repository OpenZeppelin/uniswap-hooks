// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseBeforeSwapHookFee} from "src/fee/BaseBeforeSwapHookFee.sol";
import {BaseAfterSwapHookFee} from "src/fee/BaseAfterSwapHookFee.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "src/base/BaseHook.sol";

/*
* @dev Mock contract for testing the combined hook fee implemementation of {BaseBeforeSwapHookFee} and {BaseAfterSwapHookFee}.
*/
contract BaseHookFeeCombinedMock is BaseBeforeSwapHookFee, BaseAfterSwapHookFee {
    uint128 private _unspecifiedHookFeeAfter;
    uint128 private _specifiedHookFeeBefore;
    uint128 private _unspecifiedHookFeeBefore;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function setMockHookFee(uint128 specifiedHookFeeBefore, uint128 unspecifiedHookFeeBefore, uint128 unspecifiedHookFeeAfter) external {
        _specifiedHookFeeBefore = specifiedHookFeeBefore;
        _unspecifiedHookFeeBefore = unspecifiedHookFeeBefore;
        _unspecifiedHookFeeAfter = unspecifiedHookFeeAfter;
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
        return (_specifiedHookFeeBefore, _unspecifiedHookFeeBefore);
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
        return _unspecifiedHookFeeAfter;
    }

    /*
    * @dev @inheritdoc BaseBeforeSwapHookFee
    */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override(BaseHook, BaseBeforeSwapHookFee)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return BaseBeforeSwapHookFee._beforeSwap(sender, key, params, hookData);
    }

    /*
    * @dev @inheritdoc BaseAfterSwapHookFee
    */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override(BaseHook, BaseAfterSwapHookFee) returns (bytes4, int128) {
        return BaseAfterSwapHookFee._afterSwap(sender, key, params, delta, hookData);
    }

    /**
     * @dev Set the hook permissions, specifically {afterSwap} and {afterSwapReturnDelta}.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override(BaseBeforeSwapHookFee, BaseAfterSwapHookFee) returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
