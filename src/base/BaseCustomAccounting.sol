// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/base/BaseCustomAccounting.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {ERC6909} from "v4-core/src/ERC6909.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/**
 * @dev Base implementation for custom accounting, including support for swaps and liquidity management.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseCustomAccounting is BaseHook, ERC20 {
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    error ExpiredPastDeadline();
    error PoolNotInitialized();
    error TooMuchSlippage();

    struct AddLiquidityParams {
        uint256 amount0;
        uint256 amount1;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        uint256 liquidity;
        uint256 deadline;
    }

    struct CallbackData {
        address sender;
        IPoolManager.ModifyLiquidityParams params;
    }

    PoolKey public poolKey;

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    /**
     * @dev Set the pool manager.
     */
    constructor(IPoolManager _poolManager, string memory _name, string memory _symbol)
        BaseHook(_poolManager)
        ERC20(_name, _symbol)
    {}

    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        override
        onlyPoolManager
        returns (bytes4)
    {
        // Store the pool key to be used in other functions
        poolKey = key;
        return this.beforeInitialize.selector;
    }

    // TODO: fix this swap below

    /**
     * @dev Call the custom swap logic and create a return delta to be consumed by the `PoolManager`.
     */
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        //     // Determine if the swap is exact input or exact output
        //     bool exactInput = params.amountSpecified < 0;

        //     // Determine which currency is specified and which is unspecified
        //     (Currency specified, Currency unspecified) =
        //         (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        //     // Get the positive specified amount
        //     uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        //     // Get the amount of the unspecified currency to be taken or settled
        //     uint256 unspecifiedAmount = _getAmount(
        //         specifiedAmount,
        //         exactInput ? specified : unspecified,
        //         exactInput ? unspecified : specified,
        //         params.zeroForOne,
        //         exactInput
        //     );

        //     // New delta must be returned, so store in memory
        //     BeforeSwapDelta returnDelta;

        //     if (exactInput) {
        //         specified.take(poolManager, address(this), specifiedAmount, true);
        //         unspecified.settle(poolManager, address(this), unspecifiedAmount, true);

        //         // On exact input, amount0 is specified and amount1 is unspecified.
        //         returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        //     } else {
        //         unspecified.take(poolManager, address(this), unspecifiedAmount, true);
        //         specified.settle(poolManager, address(this), specifiedAmount, true);

        //         // On exact output, amount1 is specified and amount0 is unspecified.
        //         returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        //     }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint128 liquidity)
    {
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(poolKey.tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(poolKey.tickSpacing)),
            params.amount0,
            params.amount1
        );

        BalanceDelta addedDelta = modifyLiquidity(
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
                liquidityDelta: uint256(liquidity).toInt256(),
                salt: 0
            })
        );

        _mint(params.to, liquidity);

        if (uint128(-addedDelta.amount0()) < params.amount0Min || uint128(-addedDelta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        public
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        PoolId poolId = poolKey.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        delta = modifyLiquidity(
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
                liquidityDelta: -int256(params.liquidity),
                salt: 0
            })
        );

        _burn(msg.sender, params.liquidity);
    }

    function modifyLiquidity(IPoolManager.ModifyLiquidityParams memory params) internal returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(CallbackData(msg.sender, params))), (BalanceDelta));
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.params);
            poolManager.take(poolKey.currency0, data.sender, uint256(uint128(delta.amount0())));
            poolManager.take(poolKey.currency1, data.sender, uint256(uint128(delta.amount1())));
        } else {
            (delta,) = poolManager.modifyLiquidity(poolKey, data.params, bytes(""));
            poolKey.currency0.settle(poolManager, data.sender, uint256(int256(-delta.amount0())), false);
            poolKey.currency1.settle(poolManager, data.sender, uint256(int256(-delta.amount1())), false);
        }
        return abi.encode(delta);
    }

    function _removeLiquidity(IPoolManager.ModifyLiquidityParams memory params) internal returns (BalanceDelta delta) {
        PoolId poolId = poolKey.toId();

        uint256 liquidityToRemove =
            FullMath.mulDiv(uint256(-params.liquidityDelta), poolManager.getLiquidity(poolId), totalSupply());

        params.liquidityDelta = -(liquidityToRemove.toInt256());
        (delta,) = poolManager.modifyLiquidity(poolKey, params, bytes(""));
    }

    /**
     * @dev Calculate the amount of tokens to take or send (settle).
     */
    function _getAmount(uint256 amountIn, Currency input, Currency output, bool zeroForOne, bool exactInput)
        internal
        virtual
        returns (uint256 amount);

    /**
     * @dev Set the hook permissions, specifically `beforeSwap` and `beforeSwapReturnDelta`.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
