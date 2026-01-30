// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/general/LimitOrderHook.sol)

pragma solidity ^0.8.26;

// External imports
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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

/**
 * @dev The OrderId library.
 *
 * The LimitOrderHook uses OrderIds to track distinct lifecycle instances of orders at the same pool locations.
 *
 * Orders are identified by an OrderKey computed as a hash of its parameters. Multiple users can add liquidity
 * to the same OrderKey, sharing a single position owned by the hook. When an order is filled or completely
 * cancelled, the position is removed from the pool and users withdraw their liquidity.
 *
 * If users later place a new order at the same order parameters, the OrderKey remains identical but maps
 * to a new OrderId. This ensures accounting state (currency totals, liquidity mappings, filled status) remains
 * independent between the original and subsequent orders placed at the same pool location.
 *
 * NOTE: OrderKey identifies location and direction, while OrderId identifies the unique lifecycle instance.
 * An OrderKey may map to different OrderIds over time as orders are filled and recreated.
 */
library OrderIdLibrary {
    /// @dev The order id type.
    type OrderId is uint232;

    /// @dev Compare two order ids for equality.
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
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * Note: since the PoolManager implements a ReentrancyGuard, {placeOrder, cancelOrder, withdraw} are already
 * protected from reentrancy.
 *
 * _Available since v1.1.0_
 */
abstract contract LimitOrderHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using OrderIdLibrary for OrderIdLibrary.OrderId;
    using CurrencySettler for Currency;
    using SafeCast for *;

    /// @dev The info for each OrderId
    struct OrderInfo {
        /// @dev The currency0 of the order.
        Currency currency0;
        /// @dev The currency1 of the order.
        Currency currency1;
        /// @dev The total currency0 of the order including fees resting inactive in the hook.
        uint256 currency0Total;
        /// @dev The total currency1 of the order including fees resting inactive in the hook.
        uint256 currency1Total;
        /// @dev The total liquidity of the order provided by all the limit order placers.
        uint128 liquidityTotal;
        /// @dev Whether the order is filled or not.
        bool filled;
        /// @dev The liquidity of the order owned by each placer.
        mapping(address owner => uint128 amount) liquidity;
        /// @dev Checkpoints of the `currency0Total` and `currency1Total` (accrued fees) the last time the owner
        /// added liquidity to the order, used as enhanced accounting to protect from accrued fees being stolen.
        mapping(address owner => FeesCheckpointCurrencies feeCheckpoints) feeCheckpoints;
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
        uint256 value;
    }

    /// @dev Struct of callback data for the cancel callback.
    struct CancelCallbackData {
        PoolKey key;
        int24 tickLower;
        int256 liquidityDelta;
        address to;
        bool removingAllLiquidity;
        uint256 accumulatedFees0;
        uint256 accumulatedFees1;
    }

    /// @dev Struct of callback data for the withdraw callback
    struct WithdrawCallbackData {
        Currency currency0;
        Currency currency1;
        uint256 currency0Amount;
        uint256 currency1Amount;
        address to;
    }

    /**
     * @dev Struct of fees checkpoint currencies. These are the amounts of `currency0` and `currency1` marked
     * as `currency0Total` and `currency1Total` in the `OrderInfo` struct at the time of the checkpoint.
     */
    struct FeesCheckpointCurrencies {
        uint256 currency0Fees;
        uint256 currency1Fees;
    }

    /// @dev The zero bytes.
    bytes internal constant ZERO_BYTES = bytes("");

    /// @dev The default order id, used to indicate that an order is not yet initialized.
    OrderIdLibrary.OrderId internal constant ORDER_ID_DEFAULT = OrderIdLibrary.OrderId.wrap(0);

    /// @dev The next order id to be used.
    OrderIdLibrary.OrderId private _orderIdNext = OrderIdLibrary.OrderId.wrap(1);

    /// @dev The last tick lower for each pool.
    mapping(PoolId poolId => int24 tickLowerLast) private _tickLowerLasts;

    /// @dev Tracks the `orderId` for a given `orderKey` current lifecycle instance.
    mapping(bytes32 orderKey => OrderIdLibrary.OrderId orderId) private _orderIds;

    /// @dev Tracks the `OrderInfo` for each `orderId`.
    // slither-disable-next-line uninitialized-state
    mapping(OrderIdLibrary.OrderId orderId => OrderInfo orderInfo) private _orderInfos;

    /// @dev Zero liquidity was attempted to be added or removed.
    error ZeroLiquidity();

    /// @dev Limit order was incorrectly placed in an invalid tick range.
    /// Note: limit orders can only be placed out of the current range as single side liquidity.
    error InvalidRange();

    /// @dev Limit order was already filled.
    error Filled();

    /// @dev Limit order is not filled.
    error NotFilled();

    /// @dev An unsupported callback type was received.
    error UnsupportedCallback();

    /// @dev Native currency was sent for a non-native order.
    error InvalidValue();

    /// @dev Not enough native currency was sent.
    error InsufficientValue();

    /// @dev The native currency refund failed.
    error RefundFailed();

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

    /// @dev Hooks into the `afterSwap` hook to get the ticks crossed by the swap and fills the crossed limit orders.
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

        for (; lower <= upper; lower += key.tickSpacing) {
            // note that a zeroForOne swap means that the pool is actually gaining token0, so limit
            // order fills are the opposite of swap fills, hence the inversion below
            _fillOrder(key, lower, !params.zeroForOne);
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * @dev Places a limit order by adding liquidity out of range at a specific tick. The order will be filled when the
     * pool price crosses the specified `tick`. Takes a `PoolKey` `key`, target `tick`, direction `zeroForOne` indicating
     * whether to buy currency0 or currency1, and amount of `liquidity` to place. The interaction with the `poolManager` is done
     * via the `unlock` function, which will trigger the `{unlockCallback}` function.
     */
    function placeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint128 liquidity) public payable virtual {
        if (liquidity == 0) revert ZeroLiquidity();

        // the `msg.value` should be positive if the order is a native placement, 0 otherwise.
        if (key.currency0.isAddressZero() && zeroForOne) {
            if (msg.value == 0) revert InsufficientValue();
        } else if (msg.value != 0) {
            revert InvalidValue();
        }

        // get the OrderKey and it's associated OrderId
        bytes32 orderKey = getOrderKey(key, tick, zeroForOne);
        OrderIdLibrary.OrderId orderId = getOrderId(orderKey);

        OrderInfo storage orderInfo;

        // if the order is not initialized, initialize it
        if (orderId.equals(ORDER_ID_DEFAULT)) {
            unchecked {
                _setOrderId(orderKey, orderId = _orderIdNext);
                _orderIdNext = _orderIdNext.unsafeIncrement();
            }

            orderInfo = _orderInfos[orderId];

            // set the order currencies
            orderInfo.currency0 = key.currency0;
            orderInfo.currency1 = key.currency1;
        } else {
            // get the order info
            orderInfo = _orderInfos[orderId];
        }

        // add the liquidity to the order
        unchecked {
            orderInfo.liquidityTotal += liquidity;
            orderInfo.liquidity[msg.sender] += liquidity;
        }

        // Set the currency checkpoints for the `msg.sender`. These amounts are stored and considered at withdrawal time
        // so that the user cannot steal fees accrued before the checkpoint. This means that any fees accrued in between
        // checkpoints are deducted, so the user is not entitled to them.
        // Note that the amounts in the checkpoints can only be from fees accrued, never from order fills,
        // since the checkpoint are only updated at order placement, which is only possible while the order is unfilled.
        orderInfo.feeCheckpoints[msg.sender].currency0Fees = orderInfo.currency0Total;
        orderInfo.feeCheckpoints[msg.sender].currency1Fees = orderInfo.currency1Total;

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`
        // note that multiple functions trigger `unlockCallback`, so the `callbackData.callbackType` will determine what happens
        // in `unlockCallback`. In this case, it will add liquidity out of range.
        // IMPORTANT: `tick` must be valid, i.e. within the range of `MIN_TICK` and `MAX_TICK`, defined in the `TickMath` library and it must be
        // a multiple of `key.tickSpacing`.
        (uint256 amount0Fee, uint256 amount1Fee) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        CallbackType.Place,
                        abi.encode(PlaceCallbackData(key, msg.sender, zeroForOne, tick, liquidity, msg.value))
                    )
                )
            ),
            (uint256, uint256)
        );

        // add any accrued fees to the order info
        // note that the currency totals must be updated after poolManager call as they depend on the returned values of the callback.
        // This is safe as these functions are only callable on the trusted poolManager
        unchecked {
            // slither-disable-next-line reentrancy-no-eth
            orderInfo.currency0Total += amount0Fee;
            // slither-disable-next-line reentrancy-no-eth
            orderInfo.currency1Total += amount1Fee;
        }

        // emit the place event
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
        // get the OrderId and it's associated OrderInfo
        OrderIdLibrary.OrderId orderId = getOrderId(key, tickLower, zeroForOne);
        OrderInfo storage orderInfo = _orderInfos[orderId];

        // revert if the order is already filled
        if (orderInfo.filled) revert Filled();

        // get the liquidity added by the msg.sender
        uint128 liquidity = orderInfo.liquidity[msg.sender];

        // revert if the liquidity is 0
        if (liquidity == 0) revert ZeroLiquidity();

        // delete the liquidity from the order
        delete orderInfo.liquidity[msg.sender];

        bool removingAllLiquidity = liquidity == orderInfo.liquidityTotal;
        // subtract the liquidity from the total liquidity
        orderInfo.liquidityTotal -= liquidity;

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`
        // and remove the liquidity from the pool. Note that this function will return the fees accrued
        // by the position, since the limit order is a liquidity addition.
        // Note that `amount0Fee` and `amount1Fee` are the fees accrued by the position and will not be transferred to
        // the `to` address. Instead, they will be added to the order info (benefiting the remaining limit order placers).
        (uint256 amount0Fee, uint256 amount1Fee) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        CallbackType.Cancel,
                        abi.encode(
                            CancelCallbackData(
                                key,
                                tickLower,
                                -liquidity.toInt256(),
                                to,
                                removingAllLiquidity,
                                orderInfo.currency0Total,
                                orderInfo.currency1Total
                            )
                        )
                    )
                )
            ),
            (uint256, uint256)
        );

        if (removingAllLiquidity) {
            _setOrderId(key, tickLower, zeroForOne, ORDER_ID_DEFAULT);
            orderInfo.currency0Total = 0;
            orderInfo.currency1Total = 0;
        } else {
            // add the fees to the order info
            // note that the currency totals must be updated after poolManager call as they depend on the returned values of the callback.
            // This is safe as these functions are only callable on the trusted poolManager
            unchecked {
                // slither-disable-next-line reentrancy-no-eth
                orderInfo.currency0Total += amount0Fee;
                // slither-disable-next-line reentrancy-no-eth
                orderInfo.currency1Total += amount1Fee;
            }
        }

        // emit the cancel event
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
        returns (uint256 amount0, uint256 amount1)
    {
        // get the order info
        OrderInfo storage orderInfo = _orderInfos[orderId];

        // revert if the order is not filled
        if (!orderInfo.filled) revert NotFilled();

        // get the liquidity added by the msg.sender
        uint128 liquidity = orderInfo.liquidity[msg.sender];

        // revert if the sender liquidity is 0
        if (liquidity == 0) revert ZeroLiquidity();

        // delete the sender liquidity from the order
        delete orderInfo.liquidity[msg.sender];

        // get the total liquidity in the order
        uint128 liquidityTotal = orderInfo.liquidityTotal;

        uint256 checkpointCurrency0Fees = orderInfo.feeCheckpoints[msg.sender].currency0Fees;
        uint256 checkpointCurrency1Fees = orderInfo.feeCheckpoints[msg.sender].currency1Fees;

        // Calculate the amount of currency0 and currency1 owed to the `msg.sender`.
        // Note that the user is not entitled to withdraw fees that were accrued before their placing checkpoint.
        // Since the order is filled, `currencyTotals` at this point consists of fill amounts + any accrued fees,
        // while `checkpoints` are the fees accrued before the withdrawer placed his order.
        // Therefore, `currencyTotals` minus the `checkpoints` gives us the exact amount owed to the withdrawer.
        amount0 = FullMath.mulDiv(orderInfo.currency0Total - checkpointCurrency0Fees, liquidity, liquidityTotal);
        amount1 = FullMath.mulDiv(orderInfo.currency1Total - checkpointCurrency1Fees, liquidity, liquidityTotal);

        // subtract the amount of currency0 and currency1 from the order info
        orderInfo.currency0Total -= amount0;
        orderInfo.currency1Total -= amount1;

        // update total liquidity
        orderInfo.liquidityTotal -= liquidity;

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`
        // and return the liquidity to the `to` address.
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    CallbackType.Withdraw,
                    abi.encode(WithdrawCallbackData(orderInfo.currency0, orderInfo.currency1, amount0, amount1, to))
                )
            )
        );

        // emit the withdraw event
        emit Withdraw(msg.sender, orderId, liquidity);
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

        revert UnsupportedCallback();
    }

    /**
     * @dev Internal handler for place order callbacks. Takes `placeData` containing the order details and adds the
     * specified liquidity to the pool out of range. Reverts if the order would be placed in range or on the wrong
     * side of the range.
     */
    function _handlePlaceCallback(PlaceCallbackData memory placeData)
        internal
        virtual
        returns (uint256 amount0Fee, uint256 amount1Fee)
    {
        // add the out of range liquidity to the pool
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            placeData.key,
            ModifyLiquidityParams({
                tickLower: placeData.tickLower,
                tickUpper: placeData.tickLower + placeData.key.tickSpacing,
                liquidityDelta: int256(uint256(placeData.liquidity)),
                salt: 0
            }),
            ZERO_BYTES
        );

        // collect the fees from the pool to the hook
        if (feesAccrued.amount0() > 0) {
            placeData.key.currency0
                .take(poolManager, address(this), amount0Fee = feesAccrued.amount0().toUint256(), true);
        }
        if (feesAccrued.amount1() > 0) {
            placeData.key.currency1
                .take(poolManager, address(this), amount1Fee = feesAccrued.amount1().toUint256(), true);
        }

        BalanceDelta principalDelta = callerDelta - feesAccrued;

        // order swaps currency0 to currency1, therefore should only add currency0.
        if (placeData.zeroForOne) {
            // if the order is not adding currency0, or currency1 is involved, the order is invalid
            if (principalDelta.amount0() >= 0 || principalDelta.amount1() != 0) revert InvalidRange();

            // if the currency0 is native, refund any excess in the msg value
            // Note that the poolManager is already protected from reentrancy via a reentrancy guard.
            if (placeData.key.currency0.isAddressZero()) {
                int256 refundAmount = int256(placeData.value) - -(principalDelta.amount0());
                if (refundAmount < 0) revert InsufficientValue();
                if (refundAmount > 0) {
                    (bool success,) = placeData.owner.call{value: refundAmount.toUint256()}("");
                    if (!success) revert RefundFailed();
                }
            }

            // settle the currency0 from the sender to the pool
            placeData.key.currency0.settle(poolManager, placeData.owner, (-principalDelta.amount0()).toUint256(), false);
        } else {
            // if the order is not adding currency1, or currency0 is involved, the order is invalid
            if (principalDelta.amount1() >= 0 || principalDelta.amount0() != 0) revert InvalidRange();
            // settle the currency1 from the sender to the pool
            placeData.key.currency1.settle(poolManager, placeData.owner, (-principalDelta.amount1()).toUint256(), false);
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
        returns (uint256 amount0Fee, uint256 amount1Fee)
    {
        // remove the liquidity from the pool. The fees accrued by the position are included in the `callerDelta`
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            cancelData.key,
            ModifyLiquidityParams({
                tickLower: cancelData.tickLower,
                tickUpper: cancelData.tickLower + cancelData.key.tickSpacing,
                liquidityDelta: cancelData.liquidityDelta,
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
            // if the `removingAllLiquidity` flag is false, the fees accrued will be allocated to the remaining limit order placers
            // so we need to subtract the fees from the `cancelDelta` to get the principal delta
            principalDelta = callerDelta - feesAccrued;

            // if the amount of fees in currency0 is positive, mint currency0 to the hook
            if (feesAccrued.amount0() > 0) {
                poolManager.mint(
                    address(this), cancelData.key.currency0.toId(), amount0Fee = feesAccrued.amount0().toUint256()
                );
            }

            // if the amount of fees in currency1 is positive, mint currency1 to the hook
            if (feesAccrued.amount1() > 0) {
                poolManager.mint(
                    address(this), cancelData.key.currency1.toId(), amount1Fee = feesAccrued.amount1().toUint256()
                );
            }
        } else {
            // if the `removingAllLiquidity` flag is true, the fees accrued will be allocated to the placer of the last limit order being cancelled
            // so we can just use the `cancelDelta` as the principal delta (includes fees from this modifyLiquidity)
            principalDelta = callerDelta;

            // also transfer previously accumulated fees (minted to hook by earlier cancellers)
            if (cancelData.accumulatedFees0 > 0) {
                poolManager.burn(address(this), cancelData.key.currency0.toId(), cancelData.accumulatedFees0);
                poolManager.take(cancelData.key.currency0, cancelData.to, cancelData.accumulatedFees0);
            }
            if (cancelData.accumulatedFees1 > 0) {
                poolManager.burn(address(this), cancelData.key.currency1.toId(), cancelData.accumulatedFees1);
                poolManager.take(cancelData.key.currency1, cancelData.to, cancelData.accumulatedFees1);
            }
        }

        // transfer principal to the caller (for both cases)
        if (principalDelta.amount0() > 0) {
            cancelData.key.currency0.take(poolManager, cancelData.to, principalDelta.amount0().toUint256(), false);
        }
        if (principalDelta.amount1() > 0) {
            cancelData.key.currency1.take(poolManager, cancelData.to, principalDelta.amount1().toUint256(), false);
        }
    }

    /**
     * @dev Internal handler for withdraw callbacks. Takes `withdrawData` containing withdrawal amounts and recipient,
     * burns the specified currency amounts from the hook, and transfers them to the recipient address.
     */
    function _handleWithdrawCallback(WithdrawCallbackData memory withdrawData) internal virtual {
        // if the amount of currency0 is positive, burn the currency0 from the hook
        if (withdrawData.currency0Amount > 0) {
            // burn the currency0 from the hook
            poolManager.burn(address(this), withdrawData.currency0.toId(), withdrawData.currency0Amount);
            // take the currency0 from the pool and send it to the `to` address
            poolManager.take(withdrawData.currency0, withdrawData.to, withdrawData.currency0Amount);
        }

        // if the amount of currency1 is positive, burn the currency1 from the hook
        if (withdrawData.currency1Amount > 0) {
            // burn the currency1 from the hook
            poolManager.burn(address(this), withdrawData.currency1.toId(), withdrawData.currency1Amount);
            // take the currency1 from the pool and send it to the `to` address
            poolManager.take(withdrawData.currency1, withdrawData.to, withdrawData.currency1Amount);
        }
    }

    /**
     * @dev Internal handler for filling limit orders when price crosses a tick. Takes a `PoolKey` `key`, target `tickLower`,
     * and direction `zeroForOne`. Removes liquidity from filled orders, mints the received currencies to the hook, and
     * updates order state to track filled amounts.
     */
    function _fillOrder(PoolKey calldata key, int24 tickLower, bool zeroForOne) internal virtual {
        // slither-disable-start calls-loop
        bytes32 orderKey = getOrderKey(key, tickLower, zeroForOne);
        OrderIdLibrary.OrderId orderId = getOrderId(orderKey);

        // if the order is not default (not initialized), fill it
        if (!orderId.equals(ORDER_ID_DEFAULT)) {
            // get the order info
            OrderInfo storage orderInfo = _orderInfos[orderId];

            // set the order as filled
            orderInfo.filled = true;

            // set the order as default (inactive)
            _setOrderId(orderKey, ORDER_ID_DEFAULT);

            // modify the liquidity to remove the order liquidity from the pool
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickLower + key.tickSpacing,
                    liquidityDelta: -orderInfo.liquidityTotal.toInt256(),
                    salt: 0
                }),
                ZERO_BYTES
            );

            // if the amount of currency0 is positive, mint the currency0 to the hook
            if (delta.amount0() > 0) {
                poolManager.mint(address(this), key.currency0.toId(), delta.amount0().toUint256());
            }

            // if the amount of currency1 is positive, mint the currency1 to the hook
            if (delta.amount1() > 0) {
                poolManager.mint(address(this), key.currency1.toId(), delta.amount1().toUint256());
            }

            // add the amount of currency0 and currency1 to the order info
            // note that the currency totals must be updated after poolManager calls as they depend on the returned values.
            // This is safe as these functions are only callable on the trusted poolManager
            unchecked {
                // slither-disable-next-line reentrancy-no-eth
                orderInfo.currency0Total += delta.amount0().toUint256();
                // slither-disable-next-line reentrancy-no-eth
                orderInfo.currency1Total += delta.amount1().toUint256();
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
        tickLower = _getTickLower(_getCurrentTick(poolId), tickSpacing);
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
     * @dev Retrieves the `orderKey` for a given pool position parameters. Takes a `PoolKey` `key`, target `tickLower`, and direction
     * `zeroForOne` indicating whether it's buying currency0 or currency1.
     */
    function getOrderKey(PoolKey memory key, int24 tickLower, bool zeroForOne) public pure returns (bytes32) {
        return keccak256(abi.encode(key, tickLower, zeroForOne));
    }

    /**
     * @dev Retrieves the current `orderKey` lifecycle `orderId` or the default `orderId` if the order is not initialized.
     */
    function getOrderId(bytes32 orderKey) public view returns (OrderIdLibrary.OrderId) {
        return _orderIds[orderKey];
    }

    /**
     * @dev Overload that retrieves the `orderId` for a given order parameters.
     */
    function getOrderId(PoolKey memory key, int24 tickLower, bool zeroForOne)
        public
        view
        returns (OrderIdLibrary.OrderId)
    {
        return getOrderId(getOrderKey(key, tickLower, zeroForOne));
    }

    /**
     * @dev Updates the current `orderKey` lifecycle `orderId`.
     */
    function _setOrderId(bytes32 orderKey, OrderIdLibrary.OrderId orderId) internal {
        _orderIds[orderKey] = orderId;
    }

    /**
     * @dev Overload that retrieves the `orderKey` for a given order parameters.
     */
    function _setOrderId(PoolKey memory key, int24 tickLower, bool zeroForOne, OrderIdLibrary.OrderId orderId)
        internal
    {
        _setOrderId(getOrderKey(key, tickLower, zeroForOne), orderId);
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
     * @dev Retrieves the liquidity of a given `orderId` owned by a given `owner`.
     */
    function getOrderLiquidity(OrderIdLibrary.OrderId orderId, address owner) external view returns (uint256) {
        return _orderInfos[orderId].liquidity[owner];
    }

    /**
     * @dev Retrieves the current tick of a given `poolId`.
     */
    function _getCurrentTick(PoolId poolId) internal view returns (int24 tick) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /**
     * @dev Retrieves the `OrderInfo` for a given `orderId`.
     */
    function getOrderInfo(OrderIdLibrary.OrderId orderId)
        external
        view
        returns (
            bool filled,
            Currency currency0,
            Currency currency1,
            uint256 currency0Total,
            uint256 currency1Total,
            uint128 liquidityTotal
        )
    {
        return (
            _orderInfos[orderId].filled,
            _orderInfos[orderId].currency0,
            _orderInfos[orderId].currency1,
            _orderInfos[orderId].currency0Total,
            _orderInfos[orderId].currency1Total,
            _orderInfos[orderId].liquidityTotal
        );
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
