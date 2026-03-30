// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/general/LimitOrderHook.sol)

pragma solidity ^0.8.26;

// External imports
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// Internal imports
import {CurrencySettler} from "../utils/CurrencySettler.sol";
import {BaseHook} from "../base/BaseHook.sol";

/// @dev The order id library.
library OrderIdLibrary {
    /// @dev The order id type.
    type OrderId is uint232;

    /**
     * @dev Compare two order ids for equality. Takes two `OrderId` values `a` and `b` and
     * returns whether their underlying values are equal.
     */
    function equals(OrderId a, OrderId b) internal pure returns (bool) {
        return OrderId.unwrap(a) == OrderId.unwrap(b);
    }

    /// @dev Increment the order id `a`. Might overflow.
    function unsafeIncrement(OrderId a) internal pure returns (OrderId) {
        unchecked {
            return OrderId.wrap(OrderId.unwrap(a) + 1);
        }
    }
}

/**
 * @dev Limit Order Mechanism hook.
 *
 * Allows users to place limit orders at specific ticks outside of the current price range,
 * which will be filled if the pool's price crosses the order's tick.
 *
 * Note that given the way UniswapV4 pools works, when liquidity is added out of the current range,
 * a single currency will be provided, instead of both currencies as in in-range liquidity additions.
 *
 * Orders can be cancelled at any time until they are filled and their liquidity is removed from the pool.
 * Once completely filled, the resulting liquidity can be withdrawn from the pool.
 *
 * IMPORTANT: When cancelling or adding more liquidity into an existing order, it's possible that fees
 * have been accrued. In those cases, the accrued fees are added to the order info, benefitting the remaining
 * limit order placers.
 *
 * NOTE: Since the PoolManager implements a ReentrancyGuard, {placeOrder, cancelOrder, withdraw} are already
 * protected from reentrancy.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v1.1.0_
 */
abstract contract LimitOrderHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using OrderIdLibrary for OrderIdLibrary.OrderId;
    using CurrencySettler for Currency;
    using SafeCast for *;

    /// @dev The info for each order
    struct OrderInfo {
        /// @dev The currencies of the order.
        Currency currency0;
        Currency currency1;
        /// @dev The filled amounts for each currency. Packed into one slot.
        uint128 filledAmount0;
        uint128 filledAmount1;
        /// @dev The accrued fees for each currency. Packed into one slot.
        uint128 accruedFees0;
        uint128 accruedFees1;
        /// @dev The total liquidity in the order.
        uint128 liquidityTotal;
        /// @dev The filled status of the order.
        bool filled;
        /// @dev The info for each liquidity provider in the order.
        mapping(address user => UserInfo userInfo) userInfos;
        /// @dev Monotonic accumulators of the accrued fees per liquidity unit.
        uint256 accFee0PerLiqX128;
        uint256 accFee1PerLiqX128;
    }

    /// @dev Info for each user of a given order.
    struct UserInfo {
        /// @dev Liquidity added by the user.
        uint128 liquidity;
        /// @dev Checkpoints of the accumulated fees at the time of liquidity placement.
        /// Used to compute the portion of the accumulated fees that are owed to each user.
        uint256 feeCheckpoint0X128;
        uint256 feeCheckpoint1X128;
    }

    /// @dev Types of callbacks performed by the poolManager in `{unlockCallback}`
    enum CallbackType {
        Place,
        Cancel,
        Withdraw
    }

    /// @dev Struct of callback data passed by the poolManager in `{unlockCallback}`.
    struct CallbackData {
        CallbackType callbackType;
        bytes data;
    }

    /// @dev Struct of callback data for the place callback.
    struct PlaceCallbackData {
        PoolKey key;
        address owner;
        bool zeroForOne;
        int24 tickLower;
        uint128 liquidity;
    }

    /// @dev Struct of callback data for the cancel callback.
    struct CancelCallbackData {
        PoolKey key;
        int24 tickLower;
        uint128 liquidityDelta;
        address to;
        bool removingAllLiquidity;
    }

    /// @dev Struct of callback data for the withdraw callback
    struct WithdrawCallbackData {
        Currency currency0;
        Currency currency1;
        uint128 amount0;
        uint128 amount1;
        address to;
    }

    /// @dev The Q128 constant for fixed point arithmetic.
    uint256 internal constant Q128 = 1 << 128;

    /// @dev The zero bytes.
    bytes internal constant ZERO_BYTES = bytes("");

    /// @dev The default order id, used to indicate that an order is not yet initialized.
    OrderIdLibrary.OrderId internal constant ORDER_ID_DEFAULT = OrderIdLibrary.OrderId.wrap(0);

    /// @dev The next order id to be used.
    OrderIdLibrary.OrderId private _orderIdNext = OrderIdLibrary.OrderId.wrap(1);

    /// @dev The last tick lower for each pool.
    mapping(PoolId poolId => int24 tickLowerLast) private _tickLowerLasts;

    /// @dev Tracks each order id for a given `orderKey`, defined by `keccak256` of the `poolKey`, `tickLower`, and `zeroForOne`.
    mapping(bytes32 orderKey => OrderIdLibrary.OrderId orderId) private _orderIds;

    /// @dev Tracks the order info for each order id.
    mapping(OrderIdLibrary.OrderId orderId => OrderInfo orderInfo) private _orderInfos;

    /// @dev Zero liquidity was attempted to be added or removed.
    error ZeroLiquidity();

    /// @dev Limit order was placed in range.
    error InRange();

    /// @dev Limit order placed on the wrong side of the range.
    error CrossedRange();

    /// @dev Limit order was already filled.
    error Filled();

    /// @dev Limit order is not filled.
    error NotFilled();

    /**
     * @dev Emitted when an `owner` places a limit order with the given `orderId`, in the pool identified by `key`,
     * at the given `tickLower`, `zeroForOne` indicating the direction of the order, and `liquidity` the amount of liquidity
     * added.
     */
    event Place(
        address indexed owner,
        OrderIdLibrary.OrderId indexed orderId,
        PoolKey key,
        int24 tickLower,
        bool zeroForOne,
        uint128 liquidity
    );

    /**
     * @dev Emitted when a limit order with the given `orderId` is filled in the pool identified by `key`,
     * at the given `tickLower`, `zeroForOne` indicating the direction of the order.
     */
    event Fill(OrderIdLibrary.OrderId indexed orderId, PoolKey key, int24 tickLower, bool zeroForOne);

    /**
     * @dev Emitted when an `owner` cancels a limit order with the given `orderId`, in the pool identified by `key`,
     * at the given `tickLower`, `zeroForOne` indicating the direction of the order, and `liquidity` the amount of liquidity
     * removed.
     */
    event Cancel(
        address indexed owner,
        OrderIdLibrary.OrderId indexed orderId,
        PoolKey key,
        int24 tickLower,
        bool zeroForOne,
        uint128 liquidity
    );

    /**
     * @dev Emitted when an `owner` withdraws their `liquidity` from a limit order with the given `orderId`, in the pool identified by `key`,
     * at the given `tickLower`, `zeroForOne` indicating the direction of the order.
     */
    event Withdraw(address indexed owner, OrderIdLibrary.OrderId indexed orderId, uint128 liquidity);

    /// @dev Hooks into the `afterInitialize` hook to set the last tick lower for the pool.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        _tickLowerLasts[key.toId()] = _getTickLower(tick, key.tickSpacing);

        return this.afterInitialize.selector;
    }

    /// @dev Hooks into the `afterSwap` hook to get the ticks crossed by the swap and fill the orders that are crossed, filling them.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        (int24 tickLower, int24 lower, int24 upper) = _getCrossedTicks(key.toId(), key.tickSpacing);

        if (lower > upper) return (this.afterSwap.selector, 0);

        // set the last tick lower for the pool
        _tickLowerLasts[key.toId()] = tickLower;

        // note that a zeroForOne swap means that the pool is actually gaining token0, so limit
        // order fills are the opposite of swap fills, hence the inversion below
        bool zeroForOne = !params.zeroForOne;
        for (; lower <= upper; lower += key.tickSpacing) {
            _fillOrder(key, lower, zeroForOne);
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * @dev Places a limit order by adding liquidity out of range at a specific tick. The order will be filled when the
     * pool price crosses the specified `tick`. Takes a `PoolKey` `key`, target `tick`, direction `zeroForOne` indicating
     * whether to buy currency0 or currency1, and amount of `liquidity` to place. The interaction with the `poolManager` is done
     * via the `unlock` function, which will trigger the `{unlockCallback}` function.
     *
     * NOTE: If the placer adds more liquidity to an order placed before, any previous fees accrued are forfeited and
     * redistributed to the rest of the liquidity providers, reflected in their feeCheckpoints accordingly.
     */
    function placeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint128 liquidity) public virtual {
        if (liquidity == 0) revert ZeroLiquidity();

        (OrderIdLibrary.OrderId orderId, OrderInfo storage orderInfo) = _getOrInitializeOrder(key, tick, zeroForOne);
        UserInfo storage userInfo = orderInfo.userInfos[msg.sender];

        // Unlock the callback to the poolManage to add liquidity out of range.
        (uint128 accruedFees0, uint128 accruedFees1) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        CallbackType.Place, abi.encode(PlaceCallbackData(key, msg.sender, zeroForOne, tick, liquidity))
                    )
                )
            ),
            (uint128, uint128)
        );

        // Account accrued fees from swaps previous to this order placement.
        // NOTE: must be accounted before updating the order liquidity total.
        _accountAccruedFees(orderInfo, accruedFees0, accruedFees1);

        // Account the liquidity changes to the order
        // NOTE: must be accounted after accounting the accrued fees and before updating the user fee checkpoints.
        unchecked {
            orderInfo.liquidityTotal += liquidity;
            userInfo.liquidity += liquidity;
        }

        // Account the user fee checkpoints updates
        // NOTE: must be accounted after updating the user liquidity and the order fee accumulators.
        userInfo.feeCheckpoint0X128 = userInfo.liquidity * orderInfo.accFee0PerLiqX128;
        userInfo.feeCheckpoint1X128 = userInfo.liquidity * orderInfo.accFee1PerLiqX128;

        emit Place(msg.sender, orderId, key, tick, zeroForOne, liquidity);
    }

    /**
     * @dev Cancels a limit order by removing liquidity from the pool. Takes a `PoolKey` `key`, `tickLower` of the order,
     * direction `zeroForOne` indicating whether it was buying currency0 or currency1, and recipient address `to` for the
     * removed liquidity. Note that partial cancellation is not supported - the entire liquidity added by the msg.sender will be removed.
     * Note also that cancelling an order will cancel the order placed by the msg.sender, not orders placed by other users in the same tick range.
     * The interaction with the `poolManager` is done via the `unlock` function, which will trigger the `{unlockCallback}` function.
     */
    function cancelOrder(PoolKey calldata key, int24 tickLower, bool zeroForOne, address to) public virtual {
        OrderIdLibrary.OrderId orderId = getOrderId(key, tickLower, zeroForOne);
        OrderInfo storage orderInfo = _orderInfos[orderId];

        // revert if the order is already filled
        if (orderInfo.filled) revert Filled();

        // get the liquidity added by the msg.sender
        uint128 liquidity = orderInfo.userInfos[msg.sender].liquidity;

        // revert if the liquidity is 0
        if (liquidity == 0) revert ZeroLiquidity();

        // delete the liquidity from the order
        delete orderInfo.userInfos[msg.sender];

        bool removingAllLiquidity = liquidity == orderInfo.liquidityTotal;
        // subtract the liquidity from the total liquidity
        orderInfo.liquidityTotal -= liquidity;

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`
        // and remove the liquidity from the pool. Note that this function will return the fees accrued
        // by the position, since the limit order is a liquidity addition.
        // Note that `amount0Fee` and `amount1Fee` are the fees accrued by the position and will not be transferred to
        // the `to` address. Instead, they will be added to the order info (benefiting the remaining limit order placers).
        (uint128 accruedFees0, uint128 accruedFees1) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        CallbackType.Cancel,
                        abi.encode(CancelCallbackData(key, tickLower, liquidity, to, removingAllLiquidity))
                    )
                )
            ),
            (uint128, uint128)
        );

        if (removingAllLiquidity) {
            _setOrderId(key, tickLower, zeroForOne, ORDER_ID_DEFAULT);
            orderInfo.accruedFees0 = 0;
            orderInfo.accruedFees1 = 0;
            orderInfo.accFee0PerLiqX128 = 0;
            orderInfo.accFee1PerLiqX128 = 0;
        } else {
            // Account the accrued fees from the cancel operation
            _accountAccruedFees(orderInfo, accruedFees0, accruedFees1);
        }

        emit Cancel(msg.sender, orderId, key, tickLower, zeroForOne, liquidity);
    }

    /**
     * @dev Withdraws liquidity from a filled order, sending it to address `to`. Takes an `OrderId` `orderId` of the filled
     * order to withdraw from. Returns the withdrawn amounts as `(amount0, amount1)`. Can only be called after the order is
     * filled - use `cancelOrder` to remove liquidity from unfilled orders. The interaction with the `poolManager` is done via the
     * `unlock` function, which will trigger the `{unlockCallback}` function.
     */
    function withdraw(OrderIdLibrary.OrderId orderId, address to)
        public
        virtual
        returns (uint128 amount0, uint128 amount1)
    {
        // get the order info
        OrderInfo storage orderInfo = _orderInfos[orderId];

        // revert if the order is not filled
        if (!orderInfo.filled) revert NotFilled();

        // get the liquidity added by the msg.sender
        UserInfo memory userInfo = orderInfo.userInfos[msg.sender];

        // revert if the user liquidity is 0
        if (userInfo.liquidity == 0) revert ZeroLiquidity();

        // get the total liquidity in the order
        uint128 liquidityTotal = orderInfo.liquidityTotal;

        uint128 amount0Fill =
            uint128(Math.mulDiv(orderInfo.filledAmount0, userInfo.liquidity, liquidityTotal, Math.Rounding.Floor));
        uint128 amount1Fill =
            uint128(Math.mulDiv(orderInfo.filledAmount1, userInfo.liquidity, liquidityTotal, Math.Rounding.Floor));
        uint128 amount0Fee =
            uint128(((userInfo.liquidity * orderInfo.accFee0PerLiqX128) - userInfo.feeCheckpoint0X128) >> 128);
        uint128 amount1Fee =
            uint128(((userInfo.liquidity * orderInfo.accFee1PerLiqX128) - userInfo.feeCheckpoint1X128) >> 128);

        // subtract the withdrawn amount from the order buckets
        delete orderInfo.userInfos[msg.sender];
        orderInfo.liquidityTotal -= userInfo.liquidity;
        orderInfo.filledAmount0 -= amount0Fill;
        orderInfo.filledAmount1 -= amount1Fill;
        orderInfo.accruedFees0 -= amount0Fee;
        orderInfo.accruedFees1 -= amount1Fee;

        amount0 = amount0Fill + amount0Fee;
        amount1 = amount1Fill + amount1Fee;

        // Unlock callback to the poolManager. The callback will withdrawn currency to `to`.
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    CallbackType.Withdraw,
                    abi.encode(WithdrawCallbackData(orderInfo.currency0, orderInfo.currency1, amount0, amount1, to))
                )
            )
        );

        emit Withdraw(msg.sender, orderId, userInfo.liquidity);
    }

    /**
     * @dev Handles callbacks from the `PoolManager` for order operations. Takes encoded `rawData` containing the callback type
     * and operation-specific data. Returns encoded data containing fees accrued for cancel operations, or empty bytes
     * otherwise. Only callable by the PoolManager.
     */
    function unlockCallback(bytes calldata rawData) public virtual onlyPoolManager returns (bytes memory returnData) {
        CallbackData memory callbackData = abi.decode(rawData, (CallbackData));

        if (callbackData.callbackType == CallbackType.Place) {
            PlaceCallbackData memory placeData = abi.decode(callbackData.data, (PlaceCallbackData));
            (uint256 amount0Fee, uint256 amount1Fee) = _handlePlaceCallback(placeData);
            return abi.encode(amount0Fee, amount1Fee);
        }

        if (callbackData.callbackType == CallbackType.Cancel) {
            CancelCallbackData memory cancelData = abi.decode(callbackData.data, (CancelCallbackData));
            (uint256 amount0Fee, uint256 amount1Fee) = _handleCancelCallback(cancelData);
            return abi.encode(amount0Fee, amount1Fee);
        }

        if (callbackData.callbackType == CallbackType.Withdraw) {
            WithdrawCallbackData memory withdrawData = abi.decode(callbackData.data, (WithdrawCallbackData));
            _handleWithdrawCallback(withdrawData);
            return ZERO_BYTES;
        }
    }

    /**
     * @dev Internal handler for place order callbacks. Takes `placeData` containing the order details and adds the
     * specified liquidity to the pool out of range. Reverts if the order would be placed in range or on the wrong
     * side of the range.
     */
    function _handlePlaceCallback(PlaceCallbackData memory placeData)
        internal
        virtual
        returns (uint128 amount0Fee, uint128 amount1Fee)
    {
        PoolKey memory key = placeData.key;

        // add the out of range liquidity to the pool
        (BalanceDelta principalDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: placeData.tickLower,
                tickUpper: placeData.tickLower + key.tickSpacing,
                liquidityDelta: int256(uint256(placeData.liquidity)),
                salt: 0
            }),
            ZERO_BYTES
        );

        if (feesAccrued.amount0() > 0) {
            key.currency0.take(poolManager, address(this), amount0Fee = uint128(feesAccrued.amount0()), true);
        }
        if (feesAccrued.amount1() > 0) {
            key.currency1.take(poolManager, address(this), amount1Fee = uint128(feesAccrued.amount1()), true);
        }

        BalanceDelta delta = principalDelta - feesAccrued;

        // if the amount of currency0 is negative, the limit order is to sell `currency0` for `currency1`
        if (delta.amount0() < 0) {
            // if the amount of currency1 is not 0, the limit order is in range
            if (delta.amount1() != 0) revert InRange();
            // if `zeroForOne` is false, the limit order is wrong side of the range
            if (!placeData.zeroForOne) revert CrossedRange();

            // settle the currency0 to the owner
            key.currency0.settle(poolManager, placeData.owner, (-delta.amount0()).toUint256(), false);
        } else {
            // if the amount of currency0 is not 0, the limit order is in range
            if (delta.amount0() != 0) revert InRange();
            // if `zeroForOne` is true, the limit order is wrong side of the range
            if (placeData.zeroForOne) revert CrossedRange();

            // settle the currency1 to the owner
            key.currency1.settle(poolManager, placeData.owner, (-delta.amount1()).toUint256(), false);
        }
    }

    /**
     * @dev Internal handler for cancel order callbacks. Takes `cancelData` containing the cancellation details and
     * removes liquidity from the pool. Returns accrued fees `(amount0Fee, amount1Fee)` which are allocated to remaining
     * limit order placers, or to the cancelling user if they're removing all liquidity.
     */
    function _handleCancelCallback(CancelCallbackData memory cancelData)
        internal
        virtual
        returns (uint128 amount0Fee, uint128 amount1Fee)
    {
        int24 tickUpper = cancelData.tickLower + cancelData.key.tickSpacing;

        // remove the liquidity from the pool. The fees accrued by the position are included in the `cancelDelta`
        (BalanceDelta cancelDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            cancelData.key,
            ModifyLiquidityParams({
                tickLower: cancelData.tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -cancelData.liquidityDelta.toInt256(),
                salt: 0
            }),
            ZERO_BYTES
        );

        BalanceDelta principalDelta;

        // because `modifyPosition` includes not just principal value but also fees, we cannot allocate
        // the proceeds pro-rata. if we were to do so, users who have been in a limit order that's partially filled
        // could be unfairly diluted by a user synchronously placing then canceling a limit order to skim off fees.
        // to prevent this, we allocate all fee revenue to remaining limit order placers, unless this is the last order.
        if (!cancelData.removingAllLiquidity) {
            // if the amount of fees in currency0 is positive, mint currency0 to the hook
            if (feesAccrued.amount0() > 0) {
                poolManager.mint(
                    address(this), cancelData.key.currency0.toId(), amount0Fee = uint128(feesAccrued.amount0())
                );
            }

            // if the amount of fees in currency1 is positive, mint currency1 to the hook
            if (feesAccrued.amount1() > 0) {
                poolManager.mint(
                    address(this), cancelData.key.currency1.toId(), amount1Fee = uint128(feesAccrued.amount1())
                );
            }

            // if the `removingAllLiquidity` flag is false, the fees accrued will be allocated to the remaining limit order placers
            // so we need to subtract the fees from the `cancelDelta` to get the principal delta
            principalDelta = cancelDelta - feesAccrued;
        } else {
            // if the `removingAllLiquidity` flag is true, the fees accrued will be allocated to the placer of the last limit order being cancelled
            // so we can just use the `cancelDelta` as the principal delta
            principalDelta = cancelDelta;
        }

        // if the amount of currency0 is positive, take the currency0 from the pool and send it to the `to` address
        if (principalDelta.amount0() > 0) {
            cancelData.key.currency0.take(poolManager, cancelData.to, uint256(uint128(principalDelta.amount0())), false);
        }

        // if the amount of currency1 is positive, take the currency1 from the pool and send it to the `to` address
        if (principalDelta.amount1() > 0) {
            cancelData.key.currency1.take(poolManager, cancelData.to, uint256(uint128(principalDelta.amount1())), false);
        }
    }

    /**
     * @dev Internal handler for withdraw callbacks. Takes `withdrawData` containing withdrawal amounts and recipient,
     * burns the specified currency amounts from the hook, and transfers them to the recipient address.
     */
    function _handleWithdrawCallback(WithdrawCallbackData memory withdrawData) internal virtual {
        // if the amount of currency0 is positive, burn the currency0 from the hook
        if (withdrawData.amount0 > 0) {
            poolManager.burn(address(this), withdrawData.currency0.toId(), withdrawData.amount0);
            poolManager.take(withdrawData.currency0, withdrawData.to, withdrawData.amount0);
        }

        if (withdrawData.amount1 > 0) {
            poolManager.burn(address(this), withdrawData.currency1.toId(), withdrawData.amount1);
            poolManager.take(withdrawData.currency1, withdrawData.to, withdrawData.amount1);
        }
    }

    /**
     * @dev Accounts newly accrued fees
     * NOTE: Fee accumulators are tracked in Q128 fixed-point units per liquidity.
     * NOTE: Accumulators rounds down, so tiny residual dust can remain in the order.
     */
    function _accountAccruedFees(OrderInfo storage orderInfo, uint128 fee0, uint128 fee1) internal {
        uint128 liquidityTotal = orderInfo.liquidityTotal;
        if (liquidityTotal == 0) return;

        if (fee0 > 0) {
            orderInfo.accFee0PerLiqX128 += Math.mulDiv(fee0, Q128, liquidityTotal, Math.Rounding.Floor);
            orderInfo.accruedFees0 += fee0;
        }
        if (fee1 > 0) {
            orderInfo.accFee1PerLiqX128 += Math.mulDiv(fee1, Q128, liquidityTotal, Math.Rounding.Floor);
            orderInfo.accruedFees1 += fee1;
        }
    }

    /// @dev Retrieves the order for the given parameters, or initializes if does not exist yet.
    function _getOrInitializeOrder(PoolKey calldata key, int24 tickLower, bool zeroForOne)
        internal
        returns (OrderIdLibrary.OrderId orderId, OrderInfo storage orderInfo)
    {
        orderId = getOrderId(key, tickLower, zeroForOne);

        if (orderId.equals(ORDER_ID_DEFAULT)) {
            unchecked {
                _setOrderId(key, tickLower, zeroForOne, orderId = _orderIdNext);
                _orderIdNext = _orderIdNext.unsafeIncrement();
            }
            orderInfo = _orderInfos[orderId];
            orderInfo.currency0 = key.currency0;
            orderInfo.currency1 = key.currency1;
        } else {
            orderInfo = _orderInfos[orderId];
        }
    }

    /**
     * @dev Internal handler for filling limit orders when price crosses a tick. Takes a `PoolKey` `key`, target `tickLower`,
     * and direction `zeroForOne`. Removes liquidity from filled orders, mints the received currencies to the hook, and
     * updates order state to track filled amounts.
     */
    function _fillOrder(PoolKey calldata key, int24 tickLower, bool zeroForOne) internal virtual {
        // slither-disable-start calls-loop
        OrderIdLibrary.OrderId orderId = getOrderId(key, tickLower, zeroForOne);

        // if the order is not default (not initialized), fill it
        if (!orderId.equals(ORDER_ID_DEFAULT)) {
            // get the order info
            OrderInfo storage orderInfo = _orderInfos[orderId];

            // set the order as filled
            orderInfo.filled = true;

            // set the order as default (inactive)
            _setOrderId(key, tickLower, zeroForOne, ORDER_ID_DEFAULT);

            // modify the liquidity to remove the order liquidity from the pool
            (BalanceDelta fillDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickLower + key.tickSpacing,
                    liquidityDelta: -int256(uint256(orderInfo.liquidityTotal)),
                    salt: 0
                }),
                ZERO_BYTES
            );

            BalanceDelta principalDelta = fillDelta - feesAccrued;

            // mint all the received currencies (including fees) to the hook.
            if (fillDelta.amount0() > 0) {
                poolManager.mint(address(this), key.currency0.toId(), uint128(fillDelta.amount0()));
            }
            if (fillDelta.amount1() > 0) {
                poolManager.mint(address(this), key.currency1.toId(), uint128(fillDelta.amount1()));
            }

            // account any accrued fees.
            _accountAccruedFees(
                orderInfo,
                feesAccrued.amount0() > 0 ? uint128(feesAccrued.amount0()) : 0,
                feesAccrued.amount1() > 0 ? uint128(feesAccrued.amount1()) : 0
            );

            // account the filled amounts.
            unchecked {
                orderInfo.filledAmount0 += uint128(principalDelta.amount0());
                orderInfo.filledAmount1 += uint128(principalDelta.amount1());
            }

            emit Fill(orderId, key, tickLower, zeroForOne);
            // slither-disable-end calls-loop
        }
    }

    /**
     * @dev Internal helper that calculates the range of ticks crossed during a price change. Takes a `PoolId` `poolId`
     * and `tickSpacing`, returns the current `tickLower` and the range of ticks crossed (`lower`, `upper`) that need
     * to be checked for limit orders.
     */
    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = _getTickLower(_getTick(poolId), tickSpacing);
        int24 tickLowerLast = getTickLowerLast(poolId);

        if (tickLower < tickLowerLast) {
            lower = tickLower + tickSpacing;
            upper = tickLowerLast;
        } else {
            lower = tickLowerLast;
            upper = tickLower - tickSpacing;
        }
    }

    /**
     * @dev Returns the last recorded lower tick for a given pool. Takes a `PoolId` `poolId` and returns the
     * stored `tickLowerLast` value.
     */
    function getTickLowerLast(PoolId poolId) public view returns (int24) {
        return _tickLowerLasts[poolId];
    }

    /**
     * @dev Retrieves the order id for a given pool position. Takes a `PoolKey` `key`, target `tickLower`, and direction
     * `zeroForOne` indicating whether it's buying currency0 or currency1. Returns the {OrderId} associated with this
     * position, or the default order id if no order exists.
     */
    function getOrderId(PoolKey memory key, int24 tickLower, bool zeroForOne)
        public
        view
        returns (OrderIdLibrary.OrderId)
    {
        return _orderIds[keccak256(abi.encode(key, tickLower, zeroForOne))];
    }

    /**
     * @dev Internal helper that updates the order ID mapping. Takes a `PoolKey` `key`, target `tickLower`, direction
     * `zeroForOne`, and `orderId` to store. Associates the given order id with the pool position's hash.
     */
    function _setOrderId(PoolKey memory key, int24 tickLower, bool zeroForOne, OrderIdLibrary.OrderId orderId) private {
        _orderIds[keccak256(abi.encode(key, tickLower, zeroForOne))] = orderId;
    }

    /**
     * @dev Get the tick lower. Takes a `tick` and `tickSpacing` and returns the nearest valid tick boundary
     * at or below the input tick, accounting for negative tick handling.
     */
    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        // slither-disable-next-line divide-before-multiply
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }

    /**
     * @dev Get the current tick for a given pool. Takes a `PoolId` `poolId` and returns the tick calculated
     * from the pool's current sqrt price.
     */
    function _getTick(PoolId poolId) internal view returns (int24 tick) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /**
     * @dev Returns summarized state for an order.
     */
    function getOrderInfo(OrderIdLibrary.OrderId orderId)
        external
        view
        returns (
            bool filled,
            Currency currency0,
            Currency currency1,
            uint128 filledAmount0,
            uint128 filledAmount1,
            uint128 accruedFees0,
            uint128 accruedFees1,
            uint256 accFee0PerLiqX128,
            uint256 accFee1PerLiqX128,
            uint128 liquidityTotal
        )
    {
        OrderInfo storage orderInfo = _orderInfos[orderId];
        return (
            orderInfo.filled,
            orderInfo.currency0,
            orderInfo.currency1,
            orderInfo.filledAmount0,
            orderInfo.filledAmount1,
            orderInfo.accruedFees0,
            orderInfo.accruedFees1,
            orderInfo.accFee0PerLiqX128,
            orderInfo.accFee1PerLiqX128,
            orderInfo.liquidityTotal
        );
    }

    /**
     * @dev Get the user info for a given order id and owner. Takes an {OrderId} `orderId` and `owner` address
     * and returns the user info.
     */
    function getUserInfo(OrderIdLibrary.OrderId orderId, address owner) external view returns (UserInfo memory) {
        return _orderInfos[orderId].userInfos[owner];
    }

    /**
     * @dev Get the hook permissions for this contract. Returns a `Hooks.Permissions` struct configured to enable
     * `afterInitialize` and `afterSwap` hooks while disabling all other hooks.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}