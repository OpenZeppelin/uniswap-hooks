// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Internal imports
import {AntiSandwichHook} from "../../general/AntiSandwichHook.sol";
import {BaseHook} from "../../base/BaseHook.sol";

/**
 * @dev Hands the anti-sandwich fee to a recipient fixed at deployment, as ERC-6909 claims.
 *
 * IMPORTANT: Do not pay the fee to in-range liquidity instead. `poolManager.donate` pays whoever supplies
 * the book at that moment, and an attacker can supply almost all of it: add a dominant position, displace
 * the price, let a victim trade, close against the bound, and take the fee back through the position.
 * Delaying the donation does not help, since the position can be held across the block. Paying an address
 * the attacker does not control is what closes it.
 *
 * TIP: To route the fee to liquidity providers, the recipient has to tell liquidity that predates the fee
 * from liquidity supplied to collect it. Consider
 * https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/general/LiquidityPenaltyHook.sol[LiquidityPenaltyHook].
 */
contract AntiSandwichMock is AntiSandwichHook {
    /// @dev Receives every fee the bound collects, as ERC-6909 claims against the pool manager.
    address public immutable feeRecipient;

    constructor(IPoolManager _poolManager, address feeRecipient_) BaseHook(_poolManager) {
        feeRecipient = feeRecipient_;
    }

    /**
     * @dev Forwards the fee {BaseDynamicAfterFee} has already taken as claims.
     *
     * NOTE: The transfer reads no pool state and calls no ERC-20, so it cannot reject a swap the pool
     * accepted, and a token that charges a transfer fee, rebases or rejects a recipient has nothing to act
     * on. Redeeming the claims is the recipient's own call, where the usual token caveats apply.
     */
    function _afterSwapHandler(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        uint256,
        uint256 feeAmount
    ) internal override {
        Currency unspecified = (params.amountSpecified < 0 == params.zeroForOne) ? key.currency1 : key.currency0;

        IERC6909Claims(address(poolManager)).transfer(feeRecipient, unspecified.toId(), feeAmount);
    }

    // Exclude from coverage report
    function test() public {}
}
