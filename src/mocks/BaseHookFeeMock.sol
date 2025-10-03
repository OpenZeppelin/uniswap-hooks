// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

// Internal imports
import {CurrencySettler} from "../utils/CurrencySettler.sol";
import {BaseHookFee} from "src/fee/BaseHookFee.sol";

contract BaseHookFeeMock is BaseHookFee, AccessControl {
    using CurrencySettler for Currency;

    /// @dev The fee to be applied in hundredths of a bip (pips)
    uint24 public immutable hookFee;

    /// @dev The authorized role to withdraw fees
    bytes32 public constant WITHDRAW_FEES_ROLE = keccak256("WITHDRAW_FEES_ROLE");

    constructor(uint24 _hookFee, address _withdrawer) {
        _grantRole(WITHDRAW_FEES_ROLE, _withdrawer);
        hookFee = _hookFee;
    }

    /// @inheritdoc BaseHookFee
    function _getHookFee(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal view override returns (uint24) {
        return hookFee;
    }

    /// @dev withdraws the hook fees to the sender.
    function handleHookFees(Currency[] memory currencies) public override onlyRole(WITHDRAW_FEES_ROLE) {
        poolManager().unlock(abi.encode(currencies, msg.sender));
    }

    /// @dev callback from the poolManager to unlock and transfer the hook fees to the sender.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        IPoolManager poolManager = poolManager();

        (Currency[] memory currencies, address recipient) = abi.decode(data, (Currency[], address));

        for (uint256 i = 0; i < currencies.length; i++) {
            uint256 amount = poolManager.balanceOf(address(this), currencies[i].toId());
            if (amount > 0) {
                currencies[i].settle(poolManager, address(this), amount, true); // burn claims
                currencies[i].take(poolManager, recipient, amount, false); // take tokens
            }
        }

        return "";
    }

    // Exclude from coverage report
    function test() public {}
}
