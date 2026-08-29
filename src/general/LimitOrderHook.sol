// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/general/LimitOrderHook.sol)

pragma solidity ^0.8.26;

// External imports
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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
 * Allows users to place limit orders at specific ticks the price has not yet crossed,
 * which will be filled if the pool's price crosses the order's tick.
 *
 * Note that given the way UniswapV4 pools works, when liquidity is added out of the current range,
 * a single currency will be provided, instead of both currencies as in in-range liquidity additions.
 *
 * Orders can be cancelled at any time until they are filled and their liquidity is removed from the pool.
 * Once completely filled, the resulting liquidity can be withdrawn from the pool.
 *
 * NOTE: Fees accrued by an order are credited per unit of liquidity, so each owner is entitled to the
 * fees earned while its liquidity was in the order and to none of those earned before it. Amounts are truncated
 * in the order's favour, so a negligible residual can remain in the hook.
 *
 * NOTE: Native currency orders are not supported.
 *
 * IMPORTANT: Uniswap V4 does not call a hook's own callbacks when that hook is the caller, so {_afterSwap}
 * does not run for a swap this hook makes itself. A subclass that swaps internally MUST call
 * {_fillCrossedOrders} afterwards, or the tick recorded for the pool falls behind the price and the next
 * crossing is measured from it.
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

    /// @dev The info for each order id.
    struct OrderInfo {
        /// @dev The currencies of the order.
        Currency currency0;
        Currency currency1;
        /// @dev The principal credited to the order.
        uint256 principalCredited0;
        uint256 principalCredited1;
        /// @dev Monotonic accumulators that accumulate the accrued fees per liquidity unit.
        uint256 accFee0PerLiqX128;
        uint256 accFee1PerLiqX128;
        /// @dev The total liquidity added to the order.
        uint128 liquidityTotal;
        /// @dev Whether the order is filled.
        bool filled;
        /// @dev The info for each owner of the order.
        mapping(address owner => UserInfo) userInfo;
    }

    /// @dev Info for each owner of an order.
    struct UserInfo {
        /// @dev Liquidity added by the owner.
        uint128 liquidity;
        /// @dev Checkpoints of the order fee accumulators at the time of liquidity placement.
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
        OrderIdLibrary.OrderId orderId;
        address owner;
        bool zeroForOne;
        int24 tickLower;
        uint128 liquidity;
    }

    /// @dev Struct of callback data for the cancel callback.
    struct CancelCallbackData {
        PoolKey key;
        OrderIdLibrary.OrderId orderId;
        bool zeroForOne;
        int24 tickLower;
        uint128 liquidity;
        address owner;
        address to;
    }

    /// @dev Struct of callback data for the withdraw callback
    struct WithdrawCallbackData {
        OrderIdLibrary.OrderId orderId;
        uint128 liquidity;
        address owner;
        address to;
    }

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

    /// @dev Limit order was placed in a pool holding the native currency.
    error NativeCurrencyUnsupported();

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

    /// @dev Hooks into the `afterSwap` hook to fill the orders the swap crossed.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        _fillCrossedOrders(key, params.zeroForOne);

        return (this.afterSwap.selector, 0);
    }

    // ------------------------------------- Actions ------------------------------------- //

    /**
     * @dev Places a limit order by adding liquidity out of range at a specific tick. The order will be filled when the
     * pool price crosses the specified `tick`. Takes a `PoolKey` `key`, target `tick`, direction `zeroForOne` indicating
     * whether to buy currency0 or currency1, and amount of `liquidity` to place. The interaction with the `poolManager` is done
     * via the `unlock` function, which will trigger the `{unlockCallback}` function.
     *
     * Requirements:
     *
     * - `key` must identify a pool configured with this hook, otherwise the order could never be filled.
     * - The placement must require only the currency being sold, otherwise it reverts {InRange}.
     */
    function placeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint128 liquidity)
        public
        virtual
        onlyValidPools(key.hooks)
    {
        if (liquidity == 0) revert ZeroLiquidity();

        if (key.currency0.isAddressZero()) revert NativeCurrencyUnsupported();

        OrderInfo storage orderInfo;

        // get the order id
        OrderIdLibrary.OrderId orderId = getOrderId(key, tick, zeroForOne);

        // if the order is not initialized, initialize it
        if (orderId.equals(ORDER_ID_DEFAULT)) {
            // initialize the order with the next order id
            unchecked {
                _setOrderId(key, tick, zeroForOne, orderId = _orderIdNext);

                // increment the order id
                _orderIdNext = _orderIdNext.unsafeIncrement();
            }

            // get the order info
            orderInfo = _orderInfos[orderId];

            // set the currency0 and currency1
            orderInfo.currency0 = key.currency0;
            orderInfo.currency1 = key.currency1;
        } else {
            // get the order info
            orderInfo = _orderInfos[orderId];
        }

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`
        // note that multiple functions trigger `unlockCallback`, so the `callbackData.callbackType` will determine what happens
        // in `unlockCallback`. In this case, it will add liquidity out of range.
        // IMPORTANT: `tick` must be valid, i.e. within the range of `MIN_TICK` and `MAX_TICK`, defined in the `TickMath` library and it must be
        // a multiple of `key.tickSpacing`.
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    CallbackType.Place,
                    abi.encode(PlaceCallbackData(key, orderId, msg.sender, zeroForOne, tick, liquidity))
                )
            )
        );

        // emit the place event
        emit Place(msg.sender, orderId, key, tick, zeroForOne, liquidity);
    }

    /**
     * @dev Cancels a limit order by removing liquidity from the pool. Takes a `PoolKey` `key`, `tickLower` of the order,
     * direction `zeroForOne` indicating whether it was buying currency0 or currency1, and recipient address `to` for the
     * removed liquidity. Note that partial cancellation is not supported - the entire liquidity added by the msg.sender will be removed.
     * Note also that cancelling an order will cancel the order placed by the msg.sender, not orders placed by other users in the same tick range.
     * The interaction with the `poolManager` is done via the `unlock` function, which will trigger the `{unlockCallback}` function.
     *
     * Requirements:
     *
     * - `key` must identify a pool configured with this hook.
     */
    function cancelOrder(PoolKey calldata key, int24 tickLower, bool zeroForOne, address to)
        public
        virtual
        onlyValidPools(key.hooks)
    {
        OrderIdLibrary.OrderId orderId = getOrderId(key, tickLower, zeroForOne);
        OrderInfo storage orderInfo = _orderInfos[orderId];

        // get the liquidity added by the msg.sender
        uint128 liquidity = orderInfo.userInfo[msg.sender].liquidity;

        // revert if the liquidity is 0
        if (liquidity == 0) revert ZeroLiquidity();

        // if the msg.sender holds every unit of liquidity in the order, cancelling it leaves the order
        // empty, so set it as default (inactive)
        if (liquidity == orderInfo.liquidityTotal) {
            _setOrderId(key, tickLower, zeroForOne, ORDER_ID_DEFAULT);
        }

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`, remove the
        // liquidity from the pool and send both the principal and the fees owed to the `to` address. Note
        // that the order accounting is updated in the callback, since the fees owed depend on the fees the
        // position accrued up to the removal.
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    CallbackType.Cancel,
                    abi.encode(CancelCallbackData(key, orderId, zeroForOne, tickLower, liquidity, msg.sender, to))
                )
            )
        );

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
        OrderInfo storage orderInfo = _orderInfos[orderId];

        // revert if the order is not filled
        if (!orderInfo.filled) revert NotFilled();

        // get the liquidity added by the msg.sender
        uint128 liquidity = orderInfo.userInfo[msg.sender].liquidity;

        // revert if the liquidity is 0
        if (liquidity == 0) revert ZeroLiquidity();

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`, remove the
        // msg.sender from the order and send its share of the principal and the fees owed to it to the `to`
        // address.
        (amount0, amount1) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        CallbackType.Withdraw, abi.encode(WithdrawCallbackData(orderId, liquidity, msg.sender, to))
                    )
                )
            ),
            (uint256, uint256)
        );

        // emit the withdraw event
        emit Withdraw(msg.sender, orderId, liquidity);
    }

    // -------------------------------- Unlock callbacks --------------------------------

    /**
     * @dev Handles callbacks from the `PoolManager` for order operations. Takes encoded `rawData` containing the callback type
     * and operation-specific data. Only callable by the PoolManager.
     */
    function unlockCallback(bytes calldata rawData) public virtual onlyPoolManager returns (bytes memory returnData) {
        CallbackData memory callbackData = abi.decode(rawData, (CallbackData));

        if (callbackData.callbackType == CallbackType.Place) {
            PlaceCallbackData memory placeData = abi.decode(callbackData.data, (PlaceCallbackData));
            _handlePlaceCallback(placeData);
            return ZERO_BYTES;
        }

        if (callbackData.callbackType == CallbackType.Cancel) {
            CancelCallbackData memory cancelData = abi.decode(callbackData.data, (CancelCallbackData));
            _handleCancelCallback(cancelData);
            return ZERO_BYTES;
        }

        if (callbackData.callbackType == CallbackType.Withdraw) {
            WithdrawCallbackData memory withdrawData = abi.decode(callbackData.data, (WithdrawCallbackData));
            (uint256 amount0, uint256 amount1) = _handleWithdrawCallback(withdrawData);
            return abi.encode(amount0, amount1);
        }
    }

    /**
     * @dev Internal handler for place order callbacks. Takes `placeData` containing the order details, adds the
     * specified liquidity to the pool out of range and credits it to the owner. Reverts if the order would be
     * placed in range or on the wrong side of the range.
     *
     * The fees the position accrued before this placement are credited to the owners already in the order, so
     * that the placer is not entitled to them.
     */
    function _handlePlaceCallback(PlaceCallbackData memory placeData) internal virtual {
        OrderInfo storage orderInfo = _orderInfos[placeData.orderId];
        UserInfo storage userInfo = orderInfo.userInfo[placeData.owner];
        uint128 newUserLiquidity = userInfo.liquidity + placeData.liquidity;

        // add the out of range liquidity to the pool
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            placeData.key,
            ModifyLiquidityParams({
                tickLower: placeData.tickLower,
                tickUpper: placeData.tickLower + placeData.key.tickSpacing,
                liquidityDelta: int256(uint256(placeData.liquidity)),
                salt: _getPositionSalt(placeData.zeroForOne)
            }),
            ZERO_BYTES
        );

        // collect the fees the position accrued into the order, over the liquidity that earned them
        _collectFees(orderInfo, uint256(uint128(feesAccrued.amount0())), uint256(uint128(feesAccrued.amount1())));

        // checkpoint the placer against the order's accumulators, over the liquidity they end up holding
        (uint256 owed0, uint256 owed1) = _feesOwed(orderInfo, userInfo);
        userInfo.feeCheckpoint0X128 = _feeCheckpoint(orderInfo.accFee0PerLiqX128, owed0, newUserLiquidity);
        userInfo.feeCheckpoint1X128 = _feeCheckpoint(orderInfo.accFee1PerLiqX128, owed1, newUserLiquidity);

        // update the order liquidity accounting
        unchecked {
            orderInfo.liquidityTotal += placeData.liquidity;
            userInfo.liquidity = newUserLiquidity;
        }

        // the fees were already taken as claims, so what remains owed to the pool is the principal
        BalanceDelta principalDelta = callerDelta - feesAccrued;

        // if the amount of currency0 is negative, the limit order is to sell `currency0` for `currency1`
        if (principalDelta.amount0() < 0) {
            // if the amount of currency1 is not 0, the limit order is in range
            if (principalDelta.amount1() != 0) revert InRange();
            // if `zeroForOne` is false, the limit order is wrong side of the range
            if (!placeData.zeroForOne) revert CrossedRange();

            // settle the currency0 from the placer to the pool
            placeData.key.currency0
                .settle(poolManager, placeData.owner, uint256(uint128(-principalDelta.amount0())), false);
        } else {
            // if the amount of currency0 is not 0, the limit order is in range
            if (principalDelta.amount0() != 0) revert InRange();
            // if `zeroForOne` is true, the limit order is wrong side of the range
            if (placeData.zeroForOne) revert CrossedRange();

            // settle the currency1 from the placer to the pool
            placeData.key.currency1
                .settle(poolManager, placeData.owner, uint256(uint128(-principalDelta.amount1())), false);
        }
    }

    /**
     * @dev Internal handler for cancel order callbacks. Takes `cancelData` containing the cancellation details,
     * removes the owner's liquidity from the pool and sends both its principal and the fees it is owed to the
     * recipient.
     *
     * The fees the position accrued up to the removal are credited over the liquidity that earned them, which
     * still includes the cancelling owner's, so that owner is paid its share of them and nothing is left behind.
     */
    function _handleCancelCallback(CancelCallbackData memory cancelData) internal virtual {
        OrderInfo storage orderInfo = _orderInfos[cancelData.orderId];

        // remove the liquidity from the pool. The fees accrued by the position are included in the `cancelDelta`
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            cancelData.key,
            ModifyLiquidityParams({
                tickLower: cancelData.tickLower,
                tickUpper: cancelData.tickLower + cancelData.key.tickSpacing,
                liquidityDelta: -int256(uint256(cancelData.liquidity)),
                salt: _getPositionSalt(cancelData.zeroForOne)
            }),
            ZERO_BYTES
        );

        // collect the fees the position accrued into the order, over the liquidity that earned them, which
        // still includes the liquidity being cancelled
        _collectFees(orderInfo, uint256(uint128(feesAccrued.amount0())), uint256(uint128(feesAccrued.amount1())));

        // the fees owed to the cancelling owner, including its share of the fees just credited
        (uint256 owed0, uint256 owed1) = _feesOwed(orderInfo, orderInfo.userInfo[cancelData.owner]);

        // remove the owner from the order.
        orderInfo.liquidityTotal -= cancelData.liquidity;
        delete orderInfo.userInfo[cancelData.owner];

        // the fees accrued were minted to the hook, so the principal is what remains of the `callerDelta`
        BalanceDelta principalDelta = callerDelta - feesAccrued;

        // if the amount of currency0 is positive, take the currency0 from the pool and send it to the `to` address
        if (principalDelta.amount0() > 0) {
            orderInfo.currency0.take(poolManager, cancelData.to, uint256(uint128(principalDelta.amount0())), false);
        }

        // if the amount of currency1 is positive, take the currency1 from the pool and send it to the `to` address
        if (principalDelta.amount1() > 0) {
            orderInfo.currency1.take(poolManager, cancelData.to, uint256(uint128(principalDelta.amount1())), false);
        }

        // send the fees owed to the `to` address
        _sendFromClaims(orderInfo.currency0, cancelData.to, owed0);
        _sendFromClaims(orderInfo.currency1, cancelData.to, owed1);
    }

    /**
     * @dev Internal handler for withdraw callbacks. Takes `withdrawData` containing the withdrawal details, removes
     * the owner's liquidity from the order and sends its share of the principal and the fees it is owed to the
     * recipient. Returns the amounts sent.
     *
     * The order is filled, so its liquidity was already removed from the pool and the amounts come from the claims
     * the hook holds.
     */
    function _handleWithdrawCallback(WithdrawCallbackData memory withdrawData)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1)
    {
        OrderInfo storage orderInfo = _orderInfos[withdrawData.orderId];

        uint128 liquidity = withdrawData.liquidity;
        uint128 liquidityTotal = orderInfo.liquidityTotal;

        (uint256 principal0, uint256 principal1) = _principalOwed(orderInfo, liquidity);
        (uint256 owed0, uint256 owed1) = _feesOwed(orderInfo, orderInfo.userInfo[withdrawData.owner]);

        amount0 = principal0 + owed0;
        amount1 = principal1 + owed1;

        // remove the withdrawn principal and the owner from the order
        orderInfo.principalCredited0 -= principal0;
        orderInfo.principalCredited1 -= principal1;
        orderInfo.liquidityTotal = liquidityTotal - liquidity;
        delete orderInfo.userInfo[withdrawData.owner];

        _sendFromClaims(orderInfo.currency0, withdrawData.to, amount0);
        _sendFromClaims(orderInfo.currency1, withdrawData.to, amount1);
    }

    /**
     * @dev Fills the orders the price crossed since the tick last recorded for `key`, and records the tick
     * it reached. `swapZeroForOne` is the swap's direction, not the filled orders'.
     *
     * IMPORTANT: A subclass that swaps inside its own unlock callback must call this afterwards, since the
     * pool does not report such a swap.
     */
    function _fillCrossedOrders(PoolKey memory key, bool swapZeroForOne) internal virtual {
        PoolId poolId = key.toId();
        (int24 tickLower, int24 lower, int24 upper) = _getCrossedTicks(poolId, key.tickSpacing);

        if (lower > upper) return;

        // set the last tick lower for the pool
        _tickLowerLasts[poolId] = tickLower;

        bool zeroForOne = !swapZeroForOne;
        for (; lower <= upper; lower += key.tickSpacing) {
            _fillOrder(key, lower, zeroForOne);
        }
    }

    /**
     * @dev Internal handler for filling limit orders when price crosses a tick. Takes a `PoolKey` `key`, target `tickLower`,
     * and direction `zeroForOne`. Removes liquidity from filled orders, mints the received currencies to the hook, and
     * updates order state to track filled amounts.
     */
    function _fillOrder(PoolKey memory key, int24 tickLower, bool zeroForOne) internal virtual {
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
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickLower + key.tickSpacing,
                    liquidityDelta: -int256(uint256(orderInfo.liquidityTotal)),
                    salt: _getPositionSalt(zeroForOne)
                }),
                ZERO_BYTES
            );

            uint256 amount0 = uint256(uint128(callerDelta.amount0()));
            uint256 amount1 = uint256(uint128(callerDelta.amount1()));

            uint256 amount0Fee = uint256(uint128(feesAccrued.amount0()));
            uint256 amount1Fee = uint256(uint128(feesAccrued.amount1()));

            // collect the proceeds of the removed liquidity into the order, split between the fees the
            // position accrued, credited over the liquidity that earned them, and the principal, which the
            // owners share pro-rata.
            // slither-disable-next-line reentrancy-no-eth
            _collectFees(orderInfo, amount0Fee, amount1Fee);
            // slither-disable-next-line reentrancy-no-eth
            _collectPrincipal(orderInfo, amount0 - amount0Fee, amount1 - amount1Fee);

            // emit the fill event
            emit Fill(orderId, key, tickLower, zeroForOne);
            // slither-disable-end calls-loop
        }
    }

    // -------------------------------- Order accounting -------------------------------- //

    /**
     * @dev Collects `amount0` and `amount1` of fees owed by the pool into the hook and credits them to
     * `orderInfo`, dividing them over the liquidity currently in it.
     */
    function _collectFees(OrderInfo storage orderInfo, uint256 amount0, uint256 amount1) private {
        uint128 liquidityTotal = orderInfo.liquidityTotal;
        if (liquidityTotal == 0) return;

        // note: if amount0 or amount1 are non-zero, liquidityTotal is not zero.
        if (amount0 > 0) {
            orderInfo.accFee0PerLiqX128 += FullMath.mulDiv(amount0, FixedPoint128.Q128, liquidityTotal);
            _takeAsClaims(orderInfo.currency0, amount0);
        }
        if (amount1 > 0) {
            orderInfo.accFee1PerLiqX128 += FullMath.mulDiv(amount1, FixedPoint128.Q128, liquidityTotal);
            _takeAsClaims(orderInfo.currency1, amount1);
        }
    }

    /**
     * @dev Collects `amount0` and `amount1` of principal owed by the pool into the hook and credits them to
     * `orderInfo`, to be shared pro-rata by its owners. Only a fill credits principal.
     */
    function _collectPrincipal(OrderInfo storage orderInfo, uint256 amount0, uint256 amount1) private {
        if (amount0 > 0) {
            orderInfo.principalCredited0 += amount0;
            _takeAsClaims(orderInfo.currency0, amount0);
        }
        if (amount1 > 0) {
            orderInfo.principalCredited1 += amount1;
            _takeAsClaims(orderInfo.currency1, amount1);
        }
    }

    /**
     * @dev Takes `amount` of `currency` owed by the pool as claims held by the hook.
     */
    function _takeAsClaims(Currency currency, uint256 amount) private {
        // take the currency from the pool as claims for the hook
        currency.take(poolManager, address(this), amount, true);
    }

    /**
     * @dev Sends `amount` of `currency` to `to`, redeeming the claims the hook holds for it. Returns early when
     * `amount` is zero, since the transfer it would otherwise make reverts for tokens that reject zero-value
     * transfers, and for recipients that cannot receive the native currency.
     */
    function _sendFromClaims(Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;

        // burn the claims the hook holds for the currency
        poolManager.burn(address(this), currency.toId(), amount);
        // take the currency from the pool and send it to the `to` address
        poolManager.take(currency, to, amount);
    }

    /**
     * @dev Returns the updated checkpoint that leaves `owed` fees owed to an owner holding `liquidity`, given
     * the accumulator `accFeePerLiqX128` it will be read against.
     *
     * Since fees owed are read as `(acc - checkpoint) * liquidity`, the checkpoint sits behind the accumulator
     * by `owed` expressed per unit of that liquidity. An owner adding liquidity is therefore re-checkpointed
     * without forfeiting what it had already accrued over its previous, smaller liquidity.
     *
     * The offset cannot exceed the accumulator, since those fees were owed over a liquidity no greater than
     * `liquidity`. It is zero for an owner with nothing owed, leaving the checkpoint at the accumulator.
     *
     * IMPORTANT: `liquidity` is the owner's resulting liquidity, not the amount being added, and must not be
     * zero.
     */
    function _feeCheckpoint(uint256 accFeePerLiqX128, uint256 owed, uint128 liquidity) private pure returns (uint256) {
        return accFeePerLiqX128 - FullMath.mulDiv(owed, FixedPoint128.Q128, liquidity);
    }

    /**
     * @dev Returns `liquidity`'s share of the principal credited to `orderInfo`, which is what a withdrawal
     * of that liquidity pays out. The principal is credited once by the fill and never grows, so splitting it
     * pro-rata while the total liquidity decreases alongside it is exact and independent of the order in
     * which the owners withdraw.
     */
    function _principalOwed(OrderInfo storage orderInfo, uint128 liquidity)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);

        uint128 liquidityTotal = orderInfo.liquidityTotal;
        amount0 = FullMath.mulDiv(orderInfo.principalCredited0, liquidity, liquidityTotal);
        amount1 = FullMath.mulDiv(orderInfo.principalCredited1, liquidity, liquidityTotal);
    }

    /**
     * @dev Returns the fees owed to `userInfo`, given by its liquidity's share of the accumulator growth
     * since its checkpoints. Fees are only paid out on cancellation or withdrawal, so an owner holding
     * liquidity is owed everything its checkpoints have accrued.
     */
    function _feesOwed(OrderInfo storage orderInfo, UserInfo storage userInfo)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 liquidity = userInfo.liquidity;

        amount0 =
            FullMath.mulDiv(orderInfo.accFee0PerLiqX128 - userInfo.feeCheckpoint0X128, liquidity, FixedPoint128.Q128);
        amount1 =
            FullMath.mulDiv(orderInfo.accFee1PerLiqX128 - userInfo.feeCheckpoint1X128, liquidity, FixedPoint128.Q128);
    }

    /**
     * @dev Internal helper that calculates the range of ticks crossed during a price change. Takes a `PoolId` `poolId`
     * and `tickSpacing`, returns the current `tickLower` and the range of ticks crossed (`lower`, `upper`) that need
     * to be checked for limit orders.
     */
    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        virtual
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
    function _getTickLower(int24 tick, int24 tickSpacing) internal pure virtual returns (int24) {
        // slither-disable-next-line divide-before-multiply
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }

    /**
     * @dev Get the current tick for a given pool. Takes a `PoolId` `poolId` and returns the tick the pool
     * stores, which is what marks whether a range is still active.
     */
    function _getCurrentTick(PoolId poolId) internal view virtual returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    /**
     * @dev Returns the salt of the pool position backing an order in direction `zeroForOne`. Both
     * directions at one tick span the same range, so the salt is what keeps them in separate positions.
     *
     * IMPORTANT: This value is part of a pool position's identity. Changing it on a deployed instance
     * strands the liquidity of every live order placed under the previous value.
     */
    function _getPositionSalt(bool zeroForOne) internal pure virtual returns (bytes32) {
        return zeroForOne ? bytes32(uint256(1)) : bytes32(0);
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
     * @dev Get the order info for a given order id. Takes an {OrderId} `orderId` and returns the order info.
     *
     * `accFee0PerLiqX128` and `accFee1PerLiqX128` are the fees credited to the order per unit of liquidity, as
     * `X128` fixed point values. Both only ever increase, and an owner's checkpoints are never above them.
     */
    function getOrderInfo(OrderIdLibrary.OrderId orderId)
        external
        view
        returns (
            bool filled,
            Currency currency0,
            Currency currency1,
            uint256 principalCredited0,
            uint256 principalCredited1,
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
            orderInfo.principalCredited0,
            orderInfo.principalCredited1,
            orderInfo.accFee0PerLiqX128,
            orderInfo.accFee1PerLiqX128,
            orderInfo.liquidityTotal
        );
    }

    /**
     * @dev Get the info an order holds for one of its owners. Takes an {OrderId} `orderId` and `owner` address and
     * returns the liquidity that owner placed and the values the order's fee accumulators are read against for it.
     *
     * The difference between an accumulator and its checkpoint, over `liquidity`, is the amount of fees the owner
     * is owed.
     */
    function getUserInfo(OrderIdLibrary.OrderId orderId, address owner) external view returns (UserInfo memory) {
        return _orderInfos[orderId].userInfo[owner];
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
