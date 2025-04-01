// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/general/LimitOrderHook.sol)

pragma solidity ^0.8.24;

import {BaseHook} from "src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {console} from "forge-std/console.sol";

/**
 * @dev The epoch type.
 */
type Epoch is uint232;

/**
 * @dev The epoch library.
 */
library EpochLibrary {
    /**
     * @dev Check if two epochs are equal.
     *
     * @param a The first epoch.
     * @param b The second epoch.
     * @return result The result of the comparison.
     */
    function equals(Epoch a, Epoch b) internal pure returns (bool) {
        return Epoch.unwrap(a) == Epoch.unwrap(b);
    }

    /**
     * @dev Increment the epoch.
     *
     * @param a The epoch.
     * @return result The incremented epoch.
     */
    function unsafeIncrement(Epoch a) internal pure returns (Epoch) {
        unchecked {
            return Epoch.wrap(Epoch.unwrap(a) + 1);
        }
    }
}

/**
 * @dev This hook implements a mechanism to place limit orders on a liquidity pool. Specifically,
 * it allows users to place limit orders at a specific tick, which will be filled if the price of the pool
 * crosses the tick.
 *
 * The hook implements the placing of orders by adding liquidity to the pool in a tick range out of range of the current price.
 * Note that, given the way v4 pools work, if one adds liquidity out of range, the liquidity added will be in a single currency,
 * instead of both, as in an in-range addition.
 *
 * Users can cancel their limit orders at any time until it is filled and liquidity is removed from the pool. Users can also withdraw
 * their liquidity after the limit order is filled.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.1_
 */
contract LimitOrderHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using EpochLibrary for Epoch;
    using CurrencySettler for Currency;

    /**
     * @notice The epoch info for each epoch.
     */
    struct EpochInfo {
        bool filled;
        Currency currency0;
        Currency currency1;
        uint256 currency0Total;
        uint256 currency1Total;
        uint128 liquidityTotal;
        mapping(address => uint128) liquidity;
    }

    /**
     * @notice enum of callbacks for the hook, used to determine the type of callback called from the poolManager to `unlockCallback`
     */
    enum Callbacks {
        PlaceOrder,
        CancelOrder,
        Withdraw
    }

    /**
     * @notice struct of callback data (sent from the poolManager to `unlockCallback`)
     */
    struct CallbackData {
        Callbacks callbackType;
        bytes data;
    }

    /**
     * @notice struct of callback data for the place callback
     */
    struct CallbackDataPlace {
        PoolKey key;
        address owner;
        bool zeroForOne;
        int24 tickLower;
        uint128 liquidity;
    }

    /**
     * @notice struct of callback data for the cancel callback
     */
    struct CallbackDataCancel {
        PoolKey key;
        int24 tickLower;
        int256 liquidityDelta;
        address to;
        bool removingAllLiquidity;
    }

    /**
     * @notice struct of callback data for the withdraw callback
     */
    struct CallbackDataWithdraw {
        Currency currency0;
        Currency currency1;
        uint256 currency0Amount;
        uint256 currency1Amount;
        address to;
    }

    /**
     * @notice The zero bytes.
     */
    bytes internal constant ZERO_BYTES = bytes("");

    /**
     * @notice The default epoch, used to indicate that an epoch is not yet initialized.
     */
    Epoch private constant EPOCH_DEFAULT = Epoch.wrap(0);

    /**
     * @notice The next epoch to be used.
     */
    Epoch public epochNext = Epoch.wrap(1);

    /**
     * @notice The last tick lower for each pool.
     */
    mapping(PoolId => int24) public tickLowerLasts;

    /**
     * @notice Tracks each epoch for a given identifier, defined by keccak256 of the key, tick lower, and zero for one.
     */
    mapping(bytes32 => Epoch) public epochs;

    /**
     * @notice Tracks the epoch info for each epoch.
     */
    mapping(Epoch => EpochInfo) public epochInfos;

    /**
     * @dev Zero liquidity was attempted to be added or removed.
     */
    error ZeroLiquidity();

    /* 
     * @dev Limit order was placed in range
    */
    error InRange();

    /**
     * @dev Limit order placed on the wrong side of the range
     */
    error CrossedRange();

    /**
     * @dev Hook was already initialized.
     */
    error AlreadyInitialized();

    /**
     * @dev Limit order was already filled.
     */
    error Filled();

    /**
     * @dev Limit order is not filled.
     */
    error NotFilled();

    /**
     * @dev event emitted when a limit order is placed
     */
    event Place(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );

    /**
     * @dev event emitted when a limit order is filled
     */
    event Fill(Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne);

    /**
     * @dev event emitted when a limit order is canceled
     */
    event Cancel(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );

    /**
     * @dev event emitted when a limit order is withdrawn
     */
    event Withdraw(address indexed owner, Epoch indexed epoch, uint128 liquidity);

    /**
     * @dev Set the `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Hooks into the `afterInitialize` hook to set the last tick lower for the pool.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        setTickLowerLast(key.toId(), getTickLower(tick, key.tickSpacing));

        return this.afterInitialize.selector;
    }

    /**
     * @dev Hooks into the `afterSwap` hook to get the ticks crossed by the swap and fill the epochs that are crossed, filling the limit orders.
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal virtual override returns (bytes4, int128) {
        (int24 tickLower, int24 lower, int24 upper) = _getCrossedTicks(key.toId(), key.tickSpacing);

        if (lower > upper) return (this.afterSwap.selector, 0);

        // note that a zeroForOne swap means that the pool is actually gaining token0, so limit
        // order fills are the opposite of swap fills, hence the inversion below
        bool zeroForOne = !params.zeroForOne;
        for (; lower <= upper; lower += key.tickSpacing) {
            _fillEpoch(key, lower, zeroForOne);
        }

        setTickLowerLast(key.toId(), tickLower);

        return (this.afterSwap.selector, 0);
    }

    /**
     * @dev Place a limit order.
     *
     * @dev The limit order is placed as a liquidity addition out of range, so it will be filled if the price crosses the tick.
     *
     * @param key The pool key.
     * @param tick The tick to place the limit order at.
     * @param zeroForOne Whether the limit order is for buy `currency0` or `currency1`.
     * @param liquidity The liquidity to place.
     */
    function placeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint128 liquidity) external {
        // revert if liquidity is 0
        if (liquidity == 0) revert ZeroLiquidity();

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`
        // note that multiple functions trigger `unlockCallback`, so the callbackData.callbackType will determine what happens
        // in `unlockCallback`. In this case, it will add liquiidty out of range.
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    Callbacks.PlaceOrder, abi.encode(CallbackDataPlace(key, msg.sender, zeroForOne, tick, liquidity))
                )
            )
        );

        EpochInfo storage epochInfo;

        // get the epoch for the limit order
        Epoch epoch = getEpoch(key, tick, zeroForOne);

        // if the epoch is not initialized, initialize it
        if (epoch.equals(EPOCH_DEFAULT)) {
            // initialize the epoch to the next epoch
            unchecked {
                setEpoch(key, tick, zeroForOne, epoch = epochNext);

                // increment the epoch number
                epochNext = epochNext.unsafeIncrement();
            }

            // get the epoch info
            epochInfo = epochInfos[epoch];

            // set the currency0 and currency1
            epochInfo.currency0 = key.currency0;
            epochInfo.currency1 = key.currency1;
        } else {
            // get the epoch info
            epochInfo = epochInfos[epoch];
        }

        // add the liquidity to the epoch
        unchecked {
            epochInfo.liquidityTotal += liquidity;
            epochInfo.liquidity[msg.sender] += liquidity;
        }

        // emit the place event
        emit Place(msg.sender, epoch, key, tick, zeroForOne, liquidity);
    }

    /**
     * @dev Cancel a limit order.
     *
     * @dev The limit order is canceled by removing the liquidity from the epoch.
     *
     * note that this function will cancel the limit order and return the liquidity added to the `to` address. It is not possible
     * to remove liquidity partially.
     *
     * @param key The pool key.
     * @param tickLower The tick lower of the limit order.
     * @param zeroForOne Whether the limit order is for buy `currency0` or `currency1`.
     * @param to The address to send the liquidity removed to.
     */
    function cancelOrder(PoolKey calldata key, int24 tickLower, bool zeroForOne, address to) external {
        // get the epoch
        Epoch epoch = getEpoch(key, tickLower, zeroForOne);
        EpochInfo storage epochInfo = epochInfos[epoch];

        // revert if the epoch is already filled
        if (epochInfo.filled) revert Filled();

        // get the liquidity added by the msg.sender
        uint128 liquidity = epochInfo.liquidity[msg.sender];

        // revert if the liquidity is 0
        if (liquidity == 0) revert ZeroLiquidity();

        // delete the liquidity from the epoch
        delete epochInfo.liquidity[msg.sender];

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`
        // and remove the liquidity from the pool. Note that this funciton will return the fees accrued
        // by the position, since the limit order is a liquidity addition.
        // Note that `amount0Fee` and `amount1Fee` are the fees accrued by the position and will not be transferred to
        // the `to` address. Instead, they will be added to the epoch info (benefiting the remaining limit order placers).
        (uint256 amount0Fee, uint256 amount1Fee) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        Callbacks.CancelOrder,
                        abi.encode(
                            CallbackDataCancel(
                                key, tickLower, -int256(uint256(liquidity)), to, liquidity == epochInfo.liquidityTotal
                            )
                        )
                    )
                )
            ),
            (uint256, uint256)
        );

        // subtract the liquidity from the total liquidity
        epochInfo.liquidityTotal -= liquidity;

        // add the fees to the epoch info
        unchecked {
            epochInfo.currency0Total += amount0Fee;
            epochInfo.currency1Total += amount1Fee;
        }

        // emit the cancel event
        emit Cancel(msg.sender, epoch, key, tickLower, zeroForOne, liquidity);
    }

    /**
     * @dev Withdraw the liquidity from the epoch.
     *
     * @dev This function will return the liquidity added to the `to` address.
     *
     * @notice This function will revert if the epoch is not filled. To remove liquidity before the epoch is filled, use the `cancelOrder` function.
     *
     * @param epoch The epoch to withdraw the liquidity from.
     * @param to The address to send the liquidity to.
     */
    function withdraw(Epoch epoch, address to) external returns (uint256 amount0, uint256 amount1) {
        // get the epoch info
        EpochInfo storage epochInfo = epochInfos[epoch];

        // revert if the epoch is not filled
        if (!epochInfo.filled) revert NotFilled();

        // get the liquidity added by the msg.sender
        uint128 liquidity = epochInfo.liquidity[msg.sender];

        // revert if the liquidity is 0
        if (liquidity == 0) revert ZeroLiquidity();

        // delete the liquidity from the epoch
        delete epochInfo.liquidity[msg.sender];

        // get the total liquidity in the epoch
        uint128 liquidityTotal = epochInfo.liquidityTotal;

        // calculate the amount of currency0 and currency1 owed to the msg.sender
        amount0 = FullMath.mulDiv(epochInfo.currency0Total, liquidity, liquidityTotal);
        amount1 = FullMath.mulDiv(epochInfo.currency1Total, liquidity, liquidityTotal);

        // subtract the amount of currency0 and currency1 from the epoch info
        epochInfo.currency0Total -= amount0;
        epochInfo.currency1Total -= amount1;

        // unlock the callback to the poolManager, the callback will trigger `unlockCallback`
        // and return the liquidity to the `to` address.
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    Callbacks.Withdraw,
                    abi.encode(CallbackDataWithdraw(epochInfo.currency0, epochInfo.currency1, amount0, amount1, to))
                )
            )
        );

        // emit the withdraw event
        emit Withdraw(msg.sender, epoch, liquidity);
    }

    /**
     * @dev Callback from the `PoolManager` when an order is placed, canceled or withdrawn.
     *
     * @param rawData The encoded `CallbackData` struct.
     * @return returnData The encoded caller and fees accrued deltas.
     */
    function unlockCallback(bytes calldata rawData)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes memory returnData)
    {
        // decode the callback data
        CallbackData memory callbackData = abi.decode(rawData, (CallbackData));

        // handle the callback based on the type
        if (callbackData.callbackType == Callbacks.PlaceOrder) {
            // decode the callback data
            CallbackDataPlace memory placeData = abi.decode(callbackData.data, (CallbackDataPlace));

            _handlePlaceCallback(placeData);
        } else if (callbackData.callbackType == Callbacks.CancelOrder) {
            // decode the callback data
            CallbackDataCancel memory cancelData = abi.decode(callbackData.data, (CallbackDataCancel));

            (uint256 amount0Fee, uint256 amount1Fee) = _handleCancelCallback(cancelData);

            // return the fees accrued by the position encoded in the return data
            return abi.encode(amount0Fee, amount1Fee);
        } else if (callbackData.callbackType == Callbacks.Withdraw) {
            CallbackDataWithdraw memory withdrawData = abi.decode(callbackData.data, (CallbackDataWithdraw));

            _handleWithdrawCallback(withdrawData);
        }
    }

    /**
     * @dev Handle the place callback.
     *
     * @param placeData The place data.
     */
    function _handlePlaceCallback(CallbackDataPlace memory placeData) internal {
        // get the pool key
        PoolKey memory key = placeData.key;

        // add the out of range liquidity to the pool
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: placeData.tickLower,
                tickUpper: placeData.tickLower + key.tickSpacing,
                liquidityDelta: int256(uint256(placeData.liquidity)),
                salt: 0
            }),
            ZERO_BYTES
        );

        // if the amount of currency0 is negative, the limit order is to sell `currency0` for `currency1`
        if (delta.amount0() < 0) {
            // if the amount of currency1 is not 0, the limit order is in range
            if (delta.amount1() != 0) revert InRange();
            // if `zeroForOne` is false, the limit order is wrong side of the range
            if (!placeData.zeroForOne) revert CrossedRange();

            // settle the currency0 to the owner
            key.currency0.settle(poolManager, placeData.owner, uint256(uint128(-delta.amount0())), false);
        } else {
            // if the amount of currency0 is not 0, the limit order is in range
            if (delta.amount0() != 0) revert InRange();
            // if `zeroForOne` is true, the limit order is wrong side of the range
            if (placeData.zeroForOne) revert CrossedRange();

            // settle the currency1 to the owner
            key.currency1.settle(poolManager, placeData.owner, uint256(uint128(-delta.amount1())), false);
        }
    }

    /**
     * @dev Handle the cancel callback.
     *
     * @param cancelData The cancel data.
     * @return amount0Fee The amount of currency0 fees accrued.
     * @return amount1Fee The amount of currency1 fees accrued.
     */
    function _handleCancelCallback(CallbackDataCancel memory cancelData)
        internal
        returns (uint256 amount0Fee, uint256 amount1Fee)
    {
        // get the tick upper
        int24 tickUpper = cancelData.tickLower + cancelData.key.tickSpacing;

        // because `modifyPosition` includes not just principal value but also fees, we cannot allocate
        // the proceeds pro-rata. if we were to do so, users who have been in a limit order that's partially filled
        // could be unfairly diluted by a user sychronously placing then canceling a limit order to skim off fees.
        // to prevent this, we allocate all fee revenue to remaining limit order placers, unless this is the last order.
        if (!cancelData.removingAllLiquidity) {
            (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                cancelData.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: cancelData.tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: 0,
                    salt: 0
                }),
                ZERO_BYTES
            );

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
        }

        // remove the liquidity from the pool
        // note that since the fees were already removed, we don't have to track feesAccrued again, since they're going to be 0.
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            cancelData.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: cancelData.tickLower,
                tickUpper: tickUpper,
                liquidityDelta: cancelData.liquidityDelta,
                salt: 0
            }),
            ZERO_BYTES
        );

        // if the amount of currency0 is positive, take the currency0 from the pool and send it to the `to` address
        if (delta.amount0() > 0) {
            cancelData.key.currency0.take(poolManager, cancelData.to, uint256(uint128(delta.amount0())), false);
        }

        // if the amount of currency1 is positive, take the currency1 from the pool
        if (delta.amount1() > 0) {
            cancelData.key.currency1.take(poolManager, cancelData.to, uint256(uint128(delta.amount1())), false);
        }
    }

    /**
     * @dev Handle the withdraw callback.
     *
     * @param withdrawData The withdraw data.
     */
    function _handleWithdrawCallback(CallbackDataWithdraw memory withdrawData) internal {
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
     * @dev Fill the epoch when the price crosses the tick.
     *
     * @param key The pool key.
     * @param tickLower The lower tick.
     * @param zeroForOne Whether the limit order is for buy `currency0` or `currency1`.
     */
    function _fillEpoch(PoolKey calldata key, int24 tickLower, bool zeroForOne) internal {
        // get the epoch
        Epoch epoch = getEpoch(key, tickLower, zeroForOne);

        // if the epoch is not default (not initialized), fill it
        if (!epoch.equals(EPOCH_DEFAULT)) {
            // get the epoch info
            EpochInfo storage epochInfo = epochInfos[epoch];

            // set the epoch as filled
            epochInfo.filled = true;

            uint128 amount0;
            uint128 amount1;

            // modify the liquidity to remove the epoch liquidity from the pool
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickLower + key.tickSpacing,
                    liquidityDelta: -int256(uint256(epochInfo.liquidityTotal)),
                    salt: 0
                }),
                ZERO_BYTES
            );

            // if the amount of currency0 is positive, mint the currency0 to the hook
            if (delta.amount0() > 0) {
                poolManager.mint(address(this), key.currency0.toId(), amount0 = uint128(delta.amount0()));
            }

            // if the amount of currency1 is positive, mint the currency1 to the hook
            if (delta.amount1() > 0) {
                poolManager.mint(address(this), key.currency1.toId(), amount1 = uint128(delta.amount1()));
            }

            // add the amount of currency0 and currency1 to the epoch info
            unchecked {
                epochInfo.currency0Total += amount0;
                epochInfo.currency1Total += amount1;
            }

            // set the epoch as default (inactive)
            setEpoch(key, tickLower, zeroForOne, EPOCH_DEFAULT);

            // emit the fill event
            emit Fill(epoch, key, tickLower, zeroForOne);
        }
    }

    /**
     * @dev Get the crossed ticks for a given pool after a price change.
     *
     * @param poolId The pool id.
     * @param tickSpacing The tick spacing.
     * @return tickLower The lower tick.
     * @return lower The lower tick.
     * @return upper The upper tick.
     */
    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = getTickLower(getTick(poolId), tickSpacing);
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
     * @dev Get the last tick lower.
     *
     * @param poolId The pool id.
     * @return tickLowerLast The last tick lower.
     */
    function getTickLowerLast(PoolId poolId) public view returns (int24) {
        return tickLowerLasts[poolId];
    }

    /**
     * @dev Set the last tick lower.
     *
     * @param poolId The pool id.
     * @param tickLower The tick lower.
     */
    function setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    /**
     * @dev Get the epoch for a given pool and tick.
     *
     * @param key The pool key.
     * @param tickLower The lower tick.
     * @param zeroForOne Whether the limit order is for buy `currency0` or `currency1`.
     * @return epoch The epoch.
     */
    function getEpoch(PoolKey memory key, int24 tickLower, bool zeroForOne) public view returns (Epoch) {
        return epochs[keccak256(abi.encode(key, tickLower, zeroForOne))];
    }

    /**
     * @dev Set the epoch for a given pool and tick.
     *
     * @param key The pool key.
     * @param tickLower The lower tick.
     * @param zeroForOne Whether the limit order is for buy `currency0` or `currency1`.
     * @param epoch The epoch.
     */
    function setEpoch(PoolKey memory key, int24 tickLower, bool zeroForOne, Epoch epoch) private {
        epochs[keccak256(abi.encode(key, tickLower, zeroForOne))] = epoch;
    }

    /**
     * @dev Get the tick lower.
     *
     * @param tick The tick.
     * @param tickSpacing The tick spacing.
     * @return tickLower The lower tick.
     */
    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }

    /**
     * @dev Get the epoch liquidity for a given epoch and owner.
     *
     * @param epoch The epoch.
     * @param owner The owner.
     * @return liquidity The liquidity.
     */
    function getEpochLiquidity(Epoch epoch, address owner) external view returns (uint256) {
        return epochInfos[epoch].liquidity[owner];
    }

    /**
     * @dev Get the tick for a given pool.
     *
     * @param poolId The pool id.
     * @return tick The tick.
     */
    function getTick(PoolId poolId) private view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    /**
     * @dev Set the hook permissions, specifically `afterInitialize` and `afterSwap`.
     *
     * @return permissions The hook permissions.
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
