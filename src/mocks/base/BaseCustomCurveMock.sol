// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// Internal imports
import {BaseCustomCurve} from "../../base/BaseCustomCurve.sol";
import {BaseHook} from "../../base/BaseHook.sol";

contract BaseCustomCurveMock is BaseCustomCurve, ERC20 {
    using CurrencyLibrary for Currency;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) ERC20("Mock", "MOCK") {}

    function _getUnspecifiedAmount(SwapParams calldata params)
        internal
        virtual
        override
        returns (uint256 unspecifiedAmount)
    {
        PoolKey memory key = poolKey();

        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        Currency input = exactInput ? specified : unspecified;
        Currency output = exactInput ? unspecified : specified;

        return (exactInput
                ? _getAmountOutFromExactInput(specifiedAmount, input, output, params.zeroForOne)
                : _getAmountInForExactOutput(specifiedAmount, input, output, params.zeroForOne));
    }

    function _getSwapFeeAmount(SwapParams calldata params, uint256 unspecifiedAmount)
        internal
        virtual
        override
        returns (uint256 swapFeeAmount)
    {
        return 0;
    }

    function _getAmountOutFromExactInput(uint256 amountIn, Currency, Currency, bool)
        internal
        pure
        returns (uint256 amountOut)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountOut = amountIn;
    }

    function _getAmountInForExactOutput(uint256 amountOut, Currency, Currency, bool)
        internal
        pure
        returns (uint256 amountIn)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountIn = amountOut;
    }

    /**
     * @dev Returns the claim balance the hook holds for `currency`, which is the reserve backing the shares.
     */
    function _reserve(Currency currency) internal view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }

    /**
     * @dev Quotes one share per unit of deposited value. Tokens trade 1:1 on a constant-sum curve, so the value of a
     * deposit is `amount0 + amount1` and the value of the reserves is their sum.
     */
    function _getAmountIn(AddLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        PoolKey memory key = poolKey();
        uint256 supply = totalSupply();
        uint256 value = amount0 + amount1;

        liquidity = supply == 0 ? value : value * supply / (_reserve(key.currency0) + _reserve(key.currency1));
    }

    /**
     * @dev Returns each currency pro rata to the reserves, which makes this the inverse of {_getAmountIn} while the
     * reserves are unchanged. Quoting against the reserves also keeps a redemption within what the hook holds, so a
     * swap that depletes one currency cannot block it.
     *
     * NOTE: Both formulas round down, so a partial redemption can leave dust in the hook.
     */
    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        view
        override
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        liquidity = params.liquidity;

        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0, liquidity);

        PoolKey memory key = poolKey();
        amount0 = _reserve(key.currency0) * liquidity / supply;
        amount1 = _reserve(key.currency1) * liquidity / supply;
    }

    function _mint(AddLiquidityParams memory params, BalanceDelta, BalanceDelta, uint256 liquidity) internal override {
        _mint(msg.sender, liquidity);
    }

    function _burn(RemoveLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 liquidity) internal override {
        _burn(msg.sender, liquidity);
    }

    // Exclude from coverage report
    function test() public {}
}
