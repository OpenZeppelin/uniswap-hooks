// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Internal imports
import {BaseCustomAccounting} from "../../src/base/BaseCustomAccounting.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

contract BaseCustomAccountingMock is BaseCustomAccounting, ERC20 {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint256 public nativeRefund;

    constructor(IPoolManager _poolManager) BaseCustomAccounting(_poolManager) ERC20("Mock", "MOCK") {}

    function setNativeRefund(uint256 nativeRefundFee) external {
        nativeRefund = nativeRefundFee;
    }

    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        view
        override
        returns (bytes memory modify, uint256 liquidity)
    {
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            nativeRefund > 0 ? nativeRefund : params.amount0Desired,
            nativeRefund > 0 ? nativeRefund : params.amount1Desired
        );

        return (
            abi.encode(
                ModifyLiquidityParams({
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: liquidity.toInt256(),
                    salt: params.userInputSalt
                })
            ),
            liquidity
        );
    }

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        view
        override
        returns (bytes memory, uint256 liquidity)
    {
        liquidity = FullMath.mulDiv(params.liquidity, poolManager.getLiquidity(poolKey.toId()), totalSupply());

        return (
            abi.encode(
                ModifyLiquidityParams({
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: -liquidity.toInt256(),
                    salt: params.userInputSalt
                })
            ),
            liquidity
        );
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
