// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Oracle} from "./libraries/Oracle.sol";
import {BaseHook} from "../../base/BaseHook.sol";

/// @notice A hook that enables a Uniswap V4 pool to record price observations and expose an oracle interface
contract BaseOracleHook is BaseHook {
    using Oracle for Oracle.Observation[65535];
    using StateLibrary for IPoolManager;

    /// @notice Observation cardinality cannot be increased if the pool is not initialized
    error PoolNotInitialized();

    /// @notice Emitted by the hook for increases to the number of observations that can be stored.
    /// @dev `observationCardinalityNext` is not the observation cardinality until an observation is written at the index
    /// just before a mint/swap/burn.
    /// @param observationCardinalityNextOld The previous value of the next observation cardinality
    /// @param observationCardinalityNextNew The updated value of the next observation cardinality
    event IncreaseObservationCardinalityNext(
        PoolId indexed underlyingPoolId, uint16 observationCardinalityNextOld, uint16 observationCardinalityNextNew
    );

    /// @notice Contains information about the current number of observations stored.
    /// @param index The most-recently updated index of the observations buffer
    /// @param cardinality The current maximum number of observations that are being stored
    /// @param cardinalityNext The next maximum number of observations that can be stored
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /// @notice The maximum absolute tick delta that can be observed for the truncated oracle
    int24 public immutable MAX_ABS_TICK_DELTA;

    /// @notice The list of observations for a given pool ID
    // solhint-disable-next-line
    mapping(PoolId poolId => Oracle.Observation[65535] observations) public observationsById;

    /// @notice The current observation array state for the given pool ID
    // solhint-disable-next-line
    mapping(PoolId poolId => ObservationState state) public stateById;

    /// @notice Initializes a Uniswap V4 pool with this hook, stores baseline observation state, and optionally performs a cardinality increase.
    /// @param _manager The canonical Uniswap V4 pool manager
    /// @param _maxAbsTickDelta The maximum absolute tick delta that can be observed for the truncated oracle
    constructor(IPoolManager _manager, int24 _maxAbsTickDelta) BaseHook(_manager) {
        MAX_ABS_TICK_DELTA = _maxAbsTickDelta;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The hook called after the state of a pool is initialized
    /// @param key The key for the pool being initialized
    /// @return bytes4 The function selector for the hook
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        (uint16 cardinality, uint16 cardinalityNext) =
            observationsById[poolId].initialize(uint32(block.timestamp), tick);

        stateById[poolId] = ObservationState({index: 0, cardinality: cardinality, cardinalityNext: cardinalityNext});

        return this.afterInitialize.selector;
    }

    /// @notice The hook called before a swap.
    /// @dev Note that this hook does not return either a `BeforeSwapDelta` or lp fee override — this call is used exclusively for recording price observations.
    /// @param key The key for the pool
    /// @return bytes4 The function selector for the hook
    /// @return BeforeSwapDelta The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    /// @return uint24 Optionally override the lp fee, only used if three conditions are met: 1. the Pool has a dynamic fee, 2. the value's 2nd highest bit is set (23rd bit, 0x400000), and 3. the value is less than or equal to the maximum fee (1 million)
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        ObservationState memory _observationState = stateById[poolId];

        (, int24 tick,,) = poolManager.getSlot0(poolId);

        (_observationState.index, _observationState.cardinality) = observationsById[poolId].write(
            _observationState.index,
            uint32(block.timestamp),
            tick,
            _observationState.cardinality,
            _observationState.cardinalityNext,
            MAX_ABS_TICK_DELTA
        );

        stateById[poolId] = _observationState;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Returns the cumulative tick as of each timestamp `secondsAgo` from the current block timestamp on `underlyingPoolId`.
    /// @dev To get a time weighted average tick, you must call this with two values, one representing
    /// the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted average tick,
    /// you must call it with secondsAgos = [3600, 0].
    /// @dev The time weighted average tick represents the geometric time weighted average price of the pool, in
    /// log base sqrt(1.0001) of currency1 / currency0. The TickMath library can be used to go from a tick value to a ratio.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @param underlyingPoolId The pool ID of the underlying V4 pool
    /// @return Cumulative tick values as of each `secondsAgos` from the current block timestamp
    /// @return Truncated cumulative tick values as of each `secondsAgos` from the current block timestamp
    function observe(uint32[] calldata secondsAgos, PoolId underlyingPoolId)
        external
        view
        returns (int56[] memory, int56[] memory)
    {
        ObservationState memory _observationState = stateById[underlyingPoolId];

        (, int24 tick,,) = poolManager.getSlot0(underlyingPoolId);

        return observationsById[underlyingPoolId].observe(
            uint32(block.timestamp),
            secondsAgos,
            tick,
            _observationState.index,
            _observationState.cardinality,
            MAX_ABS_TICK_DELTA
        );
    }

    /// @notice Increase the maximum number of price and liquidity observations that the oracle of `underlyingPoolId`.
    /// @param observationCardinalityNext The desired minimum number of observations for the oracle to store
    /// @param underlyingPoolId The pool ID of the underlying V4 pool
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext, PoolId underlyingPoolId) public {
        if (!observationsById[underlyingPoolId][0].initialized) revert PoolNotInitialized();

        uint16 observationCardinalityNextOld = stateById[underlyingPoolId].cardinalityNext; // for the event

        uint16 observationCardinalityNextNew =
            observationsById[underlyingPoolId].grow(observationCardinalityNextOld, observationCardinalityNext);
        stateById[underlyingPoolId].cardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew) {
            emit IncreaseObservationCardinalityNext(
                underlyingPoolId, observationCardinalityNextOld, observationCardinalityNextNew
            );
        }
    }
}
