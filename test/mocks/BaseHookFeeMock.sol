// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/fee/BaseHookFee.sol";

contract BaseHookFeeMock is BaseHookFee {
    uint256 public immutable fee;
    address public feeRecipient;

    constructor(IPoolManager _poolManager, uint256 _fee) BaseHookFee(_poolManager) {
        fee = _fee;
        feeRecipient = msg.sender;
    }

    function _getHookFee(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal view override returns (uint256) {
        return fee;
    }

    function withdrawFees(Currency[] calldata currencies) external override {
        for (uint256 i = 0; i < currencies.length; i++) {
            currencies[i].transfer(feeRecipient, currencies[i].balanceOfSelf());
        }
    }

    // Exclude from coverage report
    function test() public {}
}
