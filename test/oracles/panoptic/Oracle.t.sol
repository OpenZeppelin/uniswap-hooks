// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// External
import {Test, Vm, stdMath} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

// Internal
import {OracleHookWithV3Adapters} from "../../../src/oracles/panoptic/OracleHookWithV3Adapters.sol";
import {V3OracleAdapter} from "../../../src/oracles/panoptic/adapters/V3OracleAdapter.sol";
import {V3TruncatedOracleAdapter} from "../../../src/oracles/panoptic/adapters/V3TruncatedOracleAdapter.sol";

contract OracleTestV4 is Test, Deployers {
    using StateLibrary for IPoolManager;

    OracleHookWithV3Adapters public constant ORACLE_BASE =
        OracleHookWithV3Adapters(address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG)));

    V3OracleAdapter public oracleAdapter;

    V3TruncatedOracleAdapter public truncatedOracleAdapter;

    PoolId public poolId;

    struct InitializeParams {
        uint32 time;
        int24 tick;
    }

    struct UpdateParams {
        uint32 advanceTimeBy;
        int24 tick;
    }

    constructor() {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
    }

    function getManager() public view returns (IPoolManager) {
        return manager;
    }

    function initialize(InitializeParams memory params) public {
        vm.warp(params.time);
        vm.recordLogs();
        (key,) = initPool(
            currency0, currency1, IHooks(address(ORACLE_BASE)), 3000, 1, TickMath.getSqrtPriceAtTick(params.tick)
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        poolId = key.toId();

        (oracleAdapter, truncatedOracleAdapter) =
            abi.decode(entries[1].data, (V3OracleAdapter, V3TruncatedOracleAdapter));

        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -887270, tickUpper: 887270, liquidityDelta: 100, salt: ""});

        modifyLiquidityRouter.modifyLiquidity(key, liquidityParams, ZERO_BYTES);
    }

    function grow(uint16 _cardinality) public {
        oracleAdapter.increaseObservationCardinalityNext(_cardinality);
    }

    function growTruncated(uint16 _cardinality) public {
        truncatedOracleAdapter.increaseObservationCardinalityNext(_cardinality);
    }

    function updatePriceTo(PoolKey memory key, uint160 sqrtPriceX96) public {
        while (true) {
            (uint160 currentSqrtPriceX96,,,) = manager.getSlot0(poolId);
            if (sqrtPriceX96 == currentSqrtPriceX96) break;
            swapRouter.swap(
                key,
                SwapParams(currentSqrtPriceX96 > sqrtPriceX96 ? true : false, type(int128).min + 1, sqrtPriceX96),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
    }

    function update(UpdateParams memory params) public {
        vm.warp(block.timestamp + params.advanceTimeBy);

        // +1 to avoid tick transition
        updatePriceTo(key, TickMath.getSqrtPriceAtTick(params.tick) + 1);

        (, int24 tick,,,,,) = oracleAdapter.slot0();

        require(tick == params.tick, "tick mismatch");
    }

    function updateTruncated(UpdateParams memory params) public {
        vm.warp(block.timestamp + params.advanceTimeBy);

        (uint16 observationIndex,,) = ORACLE_BASE.stateById(poolId);

        (, int24 prevTick,,,,,) = oracleAdapter.slot0();

        (, int24 prevRecordedTickBefore,,,) = ORACLE_BASE.observationsById(poolId, observationIndex);

        // +1 to avoid tick transition
        updatePriceTo(key, TickMath.getSqrtPriceAtTick(params.tick) + 1);

        (, int24 tick,,,,,) = truncatedOracleAdapter.slot0();

        (observationIndex,,) = ORACLE_BASE.stateById(poolId);

        (, int24 prevRecordedTick,,,) = ORACLE_BASE.observationsById(poolId, observationIndex);

        require(tick == params.tick, "tick mismatch");
        if (stdMath.abs(prevRecordedTick - prevRecordedTickBefore) > 9116) {
            require(prevRecordedTick == prevTick, "prevTick mismatch");
        }
    }

    function advanceTime(uint32 by) public {
        vm.warp(block.timestamp + by);
    }

    function index() public view returns (uint16) {
        (,, uint16 observationIndex,,,,) = oracleAdapter.slot0();
        return observationIndex;
    }

    function indexTruncated() public view returns (uint16) {
        (,, uint16 observationIndex,,,,) = truncatedOracleAdapter.slot0();
        return observationIndex;
    }

    function indexBase() public view returns (uint16) {
        (uint16 observationIndex,,) = ORACLE_BASE.stateById(poolId);
        return observationIndex;
    }

    function cardinality() public view returns (uint16) {
        (,,, uint16 observationCardinality,,,) = oracleAdapter.slot0();
        return observationCardinality;
    }

    function cardinalityBase() public view returns (uint16) {
        (, uint16 observationCardinality,) = ORACLE_BASE.stateById(poolId);
        return observationCardinality;
    }

    function cardinalityTruncated() public view returns (uint16) {
        (,,, uint16 observationCardinality,,,) = truncatedOracleAdapter.slot0();
        return observationCardinality;
    }

    function cardinalityNext() public view returns (uint16) {
        (,,,, uint16 observationCardinalityNext,,) = oracleAdapter.slot0();
        return observationCardinalityNext;
    }

    function cardinalityNextBase() public view returns (uint16) {
        (,, uint16 observationCardinalityNext) = ORACLE_BASE.stateById(poolId);
        return observationCardinalityNext;
    }

    function cardinalityNextTruncated() public view returns (uint16) {
        (,,,, uint16 observationCardinalityNext,,) = truncatedOracleAdapter.slot0();
        return observationCardinalityNext;
    }

    function oracleTick() public view returns (int24) {
        (uint16 observationIndex,,) = ORACLE_BASE.stateById(poolId);

        (uint32 blockTimestamp,, int56 tickCumulative,,) = ORACLE_BASE.observationsById(poolId, observationIndex);

        (uint32 blockTimestampOld,, int56 tickCumulativeOld,,) =
            ORACLE_BASE.observationsById(poolId, observationIndex - 1);

        uint256 timeElapsed = blockTimestamp - blockTimestampOld;

        int24 tickCumulativeDelta = int24(tickCumulative - tickCumulativeOld);

        return int24(tickCumulativeDelta / int256(timeElapsed));
    }

    function truncatedOracleTick() public view returns (int24) {
        (uint16 observationIndex,,) = ORACLE_BASE.stateById(poolId);

        (uint32 blockTimestamp,,, int56 tickCumulativeTruncated,) =
            ORACLE_BASE.observationsById(poolId, observationIndex);

        (uint32 blockTimestampOld,,, int56 tickCumulativeOld,) =
            ORACLE_BASE.observationsById(poolId, observationIndex - 1);

        uint256 timeElapsed = blockTimestamp - blockTimestampOld;

        int24 tickCumulativeDelta = int24(tickCumulativeTruncated - tickCumulativeOld);

        return int24(tickCumulativeDelta / int256(timeElapsed));
    }

    function observations(uint256 _index)
        public
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        return oracleAdapter.observations(_index);
    }

    function observationsTruncated(uint256 _index)
        public
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        return truncatedOracleAdapter.observations(_index);
    }

    function observe(uint32[] memory secondsAgos) public view returns (int56[] memory, uint160[] memory) {
        return oracleAdapter.observe(secondsAgos);
    }

    function observeTruncated(uint32[] memory secondsAgos) public view returns (int56[] memory, uint160[] memory) {
        return truncatedOracleAdapter.observe(secondsAgos);
    }
}

contract OracleLibTest is Test {
    OracleTestV4 public oracle;

    uint256 constant TEST_POOL_START_TIME = 1601906400;
    uint128 constant MAX_UINT128 = type(uint128).max;

    IPoolManager public manager;

    OracleHookWithV3Adapters public constant ORACLE_BASE =
        OracleHookWithV3Adapters(address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG)));

    function setUp() public {
        oracle = new OracleTestV4();
        manager = oracle.getManager();

        deployCodeTo("OracleHookWithV3Adapters.sol", abi.encode(manager, int24(9116)), address(ORACLE_BASE));
    }

    function test_fail_increaseObservationCardinalityNext_notInitialized() public {
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.PoolNotInitialized.selector));
        ORACLE_BASE.increaseObservationCardinalityNext(1, PoolId.wrap(bytes32("1")));
    }

    function test_initialize_indexIsZero() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        assertEq(oracle.index(), 0);
        assertEq(oracle.indexBase(), 0);
    }

    function test_truncated_initialize_indexIsZero() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        assertEq(oracle.indexTruncated(), 0);
        assertEq(oracle.indexBase(), 0);
    }

    function test_initialize_cardinalityIsOne() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        assertEq(oracle.cardinality(), 1);
        assertEq(oracle.cardinalityBase(), 1);
    }

    function test_truncated_initialize_cardinalityIsOne() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        assertEq(oracle.cardinalityTruncated(), 1);
        assertEq(oracle.cardinalityBase(), 1);
    }

    function test_initialize_cardinalityNextIsOne() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        assertEq(oracle.cardinalityNext(), 1);
        assertEq(oracle.cardinalityNextBase(), 1);
    }

    function test_truncated_initialize_cardinalityNextIsOne() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        assertEq(oracle.cardinalityNextTruncated(), 1);
        assertEq(oracle.cardinalityNextBase(), 1);
    }

    function test_initialize_firstSlotTimestamp() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);
    }

    function test_truncated_initialize_firstSlotTimestamp() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 1}));
        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observationsTruncated(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);
    }

    function test_grow_increasesCardinalityNext() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.grow(5);
        assertEq(oracle.index(), 0);
        assertEq(oracle.indexBase(), 0);
        assertEq(oracle.cardinality(), 1);
        assertEq(oracle.cardinalityBase(), 1);
        assertEq(oracle.cardinalityNext(), 5);
        assertEq(oracle.cardinalityNextBase(), 5);
    }

    function test_increaseObservationCardinalityNext_increasesCardinalityNext() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(5, oracle.poolId());
        assertEq(oracle.index(), 0);
        assertEq(oracle.indexBase(), 0);
        assertEq(oracle.cardinality(), 1);
        assertEq(oracle.cardinalityBase(), 1);
        assertEq(oracle.cardinalityNext(), 5);
        assertEq(oracle.cardinalityNextBase(), 5);
    }

    function test_truncated_grow_increasesCardinalityNext() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.growTruncated(5);
        assertEq(oracle.indexTruncated(), 0);
        assertEq(oracle.indexBase(), 0);
        assertEq(oracle.cardinalityTruncated(), 1);
        assertEq(oracle.cardinalityBase(), 1);
        assertEq(oracle.cardinalityNextTruncated(), 5);
        assertEq(oracle.cardinalityNextBase(), 5);
    }

    function test_truncated_increaseObservationCardinalityNext_increasesCardinalityNext() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(5, oracle.poolId());
        assertEq(oracle.indexTruncated(), 0);
        assertEq(oracle.indexBase(), 0);
        assertEq(oracle.cardinalityTruncated(), 1);
        assertEq(oracle.cardinalityBase(), 1);
        assertEq(oracle.cardinalityNextTruncated(), 5);
        assertEq(oracle.cardinalityNextBase(), 5);
    }

    function test_grow_doesNotTouchFirstSlot() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.grow(5);
        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 0);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 0);
        assertEq(tickCumulative, 0);
    }

    function test_increaseObservationCardinalityNext_doesNotTouchFirstSlot() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(5, oracle.poolId());
        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 0);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 0);
        assertEq(tickCumulative, 0);
    }

    function test_truncated_grow_doesNotTouchFirstSlot() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.growTruncated(5);
        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observationsTruncated(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 0);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 0);
        assertEq(tickCumulative, 0);
    }

    function test_truncated_increaseObservationCardinalityNext_doesNotTouchFirstSlot() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(5, oracle.poolId());
        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observationsTruncated(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 0);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 0);
        assertEq(tickCumulative, 0);
    }

    function test_grow_isNoOpIfAlreadyLargerSize() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.grow(5);
        oracle.grow(3);
        assertEq(oracle.index(), 0);
        assertEq(oracle.indexBase(), 0);
        assertEq(oracle.cardinality(), 1);
        assertEq(oracle.cardinalityBase(), 1);
        assertEq(oracle.cardinalityNext(), 5);
        assertEq(oracle.cardinalityNextBase(), 5);
    }

    function test_increaseObservationCardinalityNext_isNoOpIfAlreadyLargerSize() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(5, oracle.poolId());
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(3, oracle.poolId());
        assertEq(oracle.index(), 0);
        assertEq(oracle.indexBase(), 0);
        assertEq(oracle.cardinality(), 1);
        assertEq(oracle.cardinalityBase(), 1);
        assertEq(oracle.cardinalityNext(), 5);
        assertEq(oracle.cardinalityNextBase(), 5);
    }

    function test_truncated_grow_isNoOpIfAlreadyLargerSize() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.growTruncated(5);
        oracle.growTruncated(3);
        assertEq(oracle.indexTruncated(), 0);
        assertEq(oracle.indexBase(), 0);
        assertEq(oracle.cardinalityTruncated(), 1);
        assertEq(oracle.cardinalityBase(), 1);
        assertEq(oracle.cardinalityNextTruncated(), 5);
        assertEq(oracle.cardinalityNextBase(), 5);
    }

    function test_truncated_increaseObservationCardinalityNext_isNoOpIfAlreadyLargerSize() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(5, oracle.poolId());
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(3, oracle.poolId());
        assertEq(oracle.indexTruncated(), 0);
        assertEq(oracle.indexBase(), 0);
        assertEq(oracle.cardinalityTruncated(), 1);
        assertEq(oracle.cardinalityBase(), 1);
        assertEq(oracle.cardinalityNextTruncated(), 5);
        assertEq(oracle.cardinalityNextBase(), 5);
    }

    function test_update_singleElementArrayOverwrite() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));

        // First update
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 2}));
        assertEq(oracle.index(), 0);
        (uint32 blockTimestamp, int56 tickCumulative,, bool initialized) = oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);

        // Second update
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 5, tick: -1}));
        (blockTimestamp, tickCumulative,, initialized) = oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 6);
        assertEq(tickCumulative, 10);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 6);
        assertEq(tickCumulative, 10);
    }

    function test_truncated_update_singleElementArrayOverwrite() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));

        // First update
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 2}));
        assertEq(oracle.indexTruncated(), 0);
        (uint32 blockTimestamp, int56 tickCumulative,, bool initialized) = oracle.observationsTruncated(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 1);
        assertEq(tickCumulative, 0);

        // Second update
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 5, tick: -1}));
        (blockTimestamp, tickCumulative,, initialized) = oracle.observationsTruncated(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 6);
        assertEq(tickCumulative, 10);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 6);
        assertEq(tickCumulative, 10);
    }

    function test_update_doesNothingIfTimeHasNotChanged() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.grow(2);

        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 3}));
        assertEq(oracle.index(), 1);
        assertEq(oracle.indexBase(), 1);

        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 0, tick: -5}));
        assertEq(oracle.index(), 1);
        assertEq(oracle.indexBase(), 1);
    }

    function test_truncated_update_doesNothingIfTimeHasNotChanged() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.growTruncated(2);

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 3}));
        assertEq(oracle.indexTruncated(), 1);
        assertEq(oracle.indexBase(), 1);

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 0, tick: -5}));
        assertEq(oracle.indexTruncated(), 1);
        assertEq(oracle.indexBase(), 1);
    }

    function test_update_writesIndexIfTimeHasChanged() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.grow(3);

        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 6, tick: 3}));
        assertEq(oracle.index(), 1);
        assertEq(oracle.indexBase(), 1);

        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 4, tick: -5}));
        assertEq(oracle.index(), 2);
        assertEq(oracle.indexBase(), 2);

        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observations(1);
        assertTrue(initialized);
        assertEq(blockTimestamp, 6);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 1);

        assertTrue(initialized);
        assertEq(blockTimestamp, 6);
        assertEq(tickCumulative, 0);
    }

    function test_truncated_update_writesIndexIfTimeHasChanged() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.growTruncated(3);

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 6, tick: 3}));
        assertEq(oracle.indexTruncated(), 1);
        assertEq(oracle.indexBase(), 1);

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 4, tick: -5}));
        assertEq(oracle.indexTruncated(), 2);
        assertEq(oracle.indexBase(), 2);

        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observationsTruncated(1);
        assertTrue(initialized);
        assertEq(blockTimestamp, 6);
        assertEq(tickCumulative, 0);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 1);

        assertTrue(initialized);
        assertEq(blockTimestamp, 6);
        assertEq(tickCumulative, 0);
    }

    function test_update_wrapsAround() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.grow(3);

        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 3, tick: 1}));
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 4, tick: 2}));
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 5, tick: 3}));

        assertEq(oracle.index(), 0);
        assertEq(oracle.indexBase(), 0);

        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observations(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 12);
        assertEq(tickCumulative, 14);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 12);
        assertEq(tickCumulative, 14);
    }

    function test_truncated_update_wrapsAround() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 0, tick: 0}));
        oracle.growTruncated(3);

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 3, tick: 1}));
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 4, tick: 2}));
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 5, tick: 3}));

        assertEq(oracle.indexTruncated(), 0);
        assertEq(oracle.indexBase(), 0);

        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            oracle.observationsTruncated(0);
        assertTrue(initialized);
        assertEq(blockTimestamp, 12);
        assertEq(tickCumulative, 14);
        assertEq(secondsPerLiquidityCumulativeX128, 0);

        (blockTimestamp, /*prevTruncatedTick*/ /*int56 tickCumulative(non-truncated)*/,, tickCumulative, initialized) =
            oracle.ORACLE_BASE().observationsById(oracle.poolId(), 0);

        assertTrue(initialized);
        assertEq(blockTimestamp, 12);
        assertEq(tickCumulative, 14);
    }

    function test_observe_fails_if_older_observation_not_exist() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 1;
        vm.expectRevert();
        oracle.observe(secondsAgos);
    }

    function test_truncated_observe_fails_if_older_observation_not_exist() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 1;
        vm.expectRevert();
        oracle.observeTruncated(secondsAgos);
    }

    function test_observe_works_across_overflow_boundary() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: type(uint32).max - 1, tick: 2}));
        oracle.advanceTime(2);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 1;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);
        assertEq(tickCumulatives[0], 2);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 2);
    }

    function test_truncated_observe_works_across_overflow_boundary() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: type(uint32).max - 1, tick: 2}));
        oracle.advanceTime(2);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 1;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);
        assertEq(tickCumulatives[0], 2);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    }

    function test_observe_single_observation_at_current_time() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 0);
    }

    function test_truncated_observe_single_observation_at_current_time() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 0);
    }

    function test_observe_single_observation_in_past_but_not_earlier_than_secondsAgo() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.advanceTime(3);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 4;
        vm.expectRevert();
        oracle.observe(secondsAgos);
    }

    function test_truncated_observe_single_observation_in_past_but_not_earlier_than_secondsAgo() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.advanceTime(3);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 4;
        vm.expectRevert();
        oracle.observeTruncated(secondsAgos);
    }

    function test_observe_single_observation_in_past_at_exactly_seconds_ago() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.advanceTime(3);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 3;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 0);
    }

    function test_truncated_observe_single_observation_in_past_at_exactly_seconds_ago() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.advanceTime(3);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 3;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 0);
    }

    function test_observe_single_observation_in_past_counterfactual_in_past() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.advanceTime(3);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 1;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);
        assertEq(tickCumulatives[0], 4);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 4);
    }

    function test_truncated_observe_single_observation_in_past_counterfactual_in_past() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.advanceTime(3);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 1;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);
        assertEq(tickCumulatives[0], 4);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 4);
    }

    function test_observe_single_observation_in_past_counterfactual_now() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.advanceTime(3);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);
        assertEq(tickCumulatives[0], 6);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 6);
    }

    function test_truncated_observe_single_observation_in_past_counterfactual_now() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.advanceTime(3);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);
        assertEq(tickCumulatives[0], 6);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 6);
    }

    function test_observe_singleObservation() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 2, tick: 2}));

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    }

    function test_truncated_observe_singleObservation() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 2, tick: 2}));

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    }

    function test_observe_multipleObservations() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 3}));
        oracle.grow(4);

        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 5}));
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 7}));

        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = 0; // current
        secondsAgos[1] = 1; // 1 second ago
        secondsAgos[2] = 2; // 2 seconds ago

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        // Verify the observations
        assertEq(tickCumulatives.length, 3);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 3);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives.length, 3);
    }

    function test_observe_multipleObservations_withIncreaseObservationCardinalityNext() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 3}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(4, oracle.poolId());

        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 5}));
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 7}));

        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = 0; // current
        secondsAgos[1] = 1; // 1 second ago
        secondsAgos[2] = 2; // 2 seconds ago

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        // Verify the observations
        assertEq(tickCumulatives.length, 3);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 3);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives.length, 3);
    }

    function test_truncated_observe_multipleObservations() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 3}));
        oracle.growTruncated(4);

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 5}));
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 7}));

        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = 0; // current
        secondsAgos[1] = 1; // 1 second ago
        secondsAgos[2] = 2; // 2 seconds ago

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        // Verify the observations
        assertEq(tickCumulatives.length, 3);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 3);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives.length, 3);
    }

    function test_truncated_observe_multipleObservations_withIncreaseObservationCardinalityNext() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 3}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(4, oracle.poolId());

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 5}));
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 7}));

        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = 0; // current
        secondsAgos[1] = 1; // 1 second ago
        secondsAgos[2] = 2; // 2 seconds ago

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        // Verify the observations
        assertEq(tickCumulatives.length, 3);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 3);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives.length, 3);
    }

    function test_observe_fetch_multiple_observations() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.grow(4);
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 13, tick: 6}));
        oracle.advanceTime(5);

        uint32[] memory secondsAgos = new uint32[](6);
        secondsAgos[0] = 0;
        secondsAgos[1] = 3;
        secondsAgos[2] = 8;
        secondsAgos[3] = 13;
        secondsAgos[4] = 15;
        secondsAgos[5] = 18;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        assertEq(tickCumulatives.length, 6);
        assertEq(tickCumulatives[0], 56);
        assertEq(tickCumulatives[1], 38);
        assertEq(tickCumulatives[2], 20);
        assertEq(tickCumulatives[3], 10);
        assertEq(tickCumulatives[4], 6);
        assertEq(tickCumulatives[5], 0);

        assertEq(secondsPerLiquidityCumulativeX128s.length, 6);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[1], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[2], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[3], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[4], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[5], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives.length, 6);
        assertEq(tickCumulatives[0], 56);
        assertEq(tickCumulatives[1], 38);
        assertEq(tickCumulatives[2], 20);
        assertEq(tickCumulatives[3], 10);
        assertEq(tickCumulatives[4], 6);
        assertEq(tickCumulatives[5], 0);
    }

    function test_observe_fetch_multiple_observations_withIncreaseObservationCardinalityNext() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(4, oracle.poolId());
        oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 13, tick: 6}));
        oracle.advanceTime(5);

        uint32[] memory secondsAgos = new uint32[](6);
        secondsAgos[0] = 0;
        secondsAgos[1] = 3;
        secondsAgos[2] = 8;
        secondsAgos[3] = 13;
        secondsAgos[4] = 15;
        secondsAgos[5] = 18;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        assertEq(tickCumulatives.length, 6);
        assertEq(tickCumulatives[0], 56);
        assertEq(tickCumulatives[1], 38);
        assertEq(tickCumulatives[2], 20);
        assertEq(tickCumulatives[3], 10);
        assertEq(tickCumulatives[4], 6);
        assertEq(tickCumulatives[5], 0);

        assertEq(secondsPerLiquidityCumulativeX128s.length, 6);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[1], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[2], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[3], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[4], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[5], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives.length, 6);
        assertEq(tickCumulatives[0], 56);
        assertEq(tickCumulatives[1], 38);
        assertEq(tickCumulatives[2], 20);
        assertEq(tickCumulatives[3], 10);
        assertEq(tickCumulatives[4], 6);
        assertEq(tickCumulatives[5], 0);
    }

    function test_truncated_observe_fetch_multiple_observations() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.growTruncated(4);
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 13, tick: 6}));
        oracle.advanceTime(5);

        uint32[] memory secondsAgos = new uint32[](6);
        secondsAgos[0] = 0;
        secondsAgos[1] = 3;
        secondsAgos[2] = 8;
        secondsAgos[3] = 13;
        secondsAgos[4] = 15;
        secondsAgos[5] = 18;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        assertEq(tickCumulatives.length, 6);
        assertEq(tickCumulatives[0], 56);
        assertEq(tickCumulatives[1], 38);
        assertEq(tickCumulatives[2], 20);
        assertEq(tickCumulatives[3], 10);
        assertEq(tickCumulatives[4], 6);
        assertEq(tickCumulatives[5], 0);

        assertEq(secondsPerLiquidityCumulativeX128s.length, 6);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[1], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[2], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[3], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[4], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[5], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives.length, 6);
        assertEq(tickCumulatives[0], 56);
        assertEq(tickCumulatives[1], 38);
        assertEq(tickCumulatives[2], 20);
        assertEq(tickCumulatives[3], 10);
        assertEq(tickCumulatives[4], 6);
        assertEq(tickCumulatives[5], 0);
    }

    function test_truncated_observe_fetch_multiple_observations_withIncreaseObservationCardinalityNext() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 5, tick: 2}));
        oracle.ORACLE_BASE().increaseObservationCardinalityNext(4, oracle.poolId());
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 13, tick: 6}));
        oracle.advanceTime(5);

        uint32[] memory secondsAgos = new uint32[](6);
        secondsAgos[0] = 0;
        secondsAgos[1] = 3;
        secondsAgos[2] = 8;
        secondsAgos[3] = 13;
        secondsAgos[4] = 15;
        secondsAgos[5] = 18;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        assertEq(tickCumulatives.length, 6);
        assertEq(tickCumulatives[0], 56);
        assertEq(tickCumulatives[1], 38);
        assertEq(tickCumulatives[2], 20);
        assertEq(tickCumulatives[3], 10);
        assertEq(tickCumulatives[4], 6);
        assertEq(tickCumulatives[5], 0);

        assertEq(secondsPerLiquidityCumulativeX128s.length, 6);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[1], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[2], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[3], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[4], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[5], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives.length, 6);
        assertEq(tickCumulatives[0], 56);
        assertEq(tickCumulatives[1], 38);
        assertEq(tickCumulatives[2], 20);
        assertEq(tickCumulatives[3], 10);
        assertEq(tickCumulatives[4], 6);
        assertEq(tickCumulatives[5], 0);
    }

    function test_full_oracle_setup() public {
        // Initialize oracle
        oracle.initialize(OracleTestV4.InitializeParams({time: uint32(TEST_POOL_START_TIME), tick: 0}));

        // Grow oracle to reasonable size for testing
        uint16 cardinalityNext = oracle.cardinalityNext();
        uint16 batchSize = 50;
        uint16 targetCardinality = 1000; // Much more reasonable than 65535
        while (cardinalityNext < targetCardinality) {
            uint16 growTo = uint16(min(uint256(targetCardinality), uint256(cardinalityNext) + batchSize));
            oracle.grow(growTo);
            cardinalityNext = growTo;
        }

        // Perform reasonable number of updates
        for (uint256 i = 0; i < targetCardinality; i += batchSize) {
            for (uint256 j = 0; j < batchSize && (i + j) < targetCardinality; j++) {
                oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 13, tick: -int24(int256(i + j))}));
            }
        }

        // Verify the oracle state
        assertEq(oracle.cardinalityNext(), targetCardinality);
        assertEq(oracle.cardinalityNextBase(), targetCardinality);
        assertEq(oracle.cardinality(), targetCardinality);
        assertEq(oracle.cardinalityBase(), targetCardinality);
        assertEq(oracle.index(), 0);
        assertEq(oracle.indexBase(), 0);
    }

    function test_full_oracle_setup_withIncreaseObservationCardinalityNext() public {
        // Initialize oracle
        oracle.initialize(OracleTestV4.InitializeParams({time: uint32(TEST_POOL_START_TIME), tick: 0}));

        // Grow oracle to reasonable size for testing
        uint16 cardinalityNext = oracle.cardinalityNext();
        uint16 targetCardinality = 1000;
        uint16 batchSize = 50;
        while (cardinalityNext < targetCardinality) {
            uint16 growTo = uint16(min(uint256(targetCardinality), uint256(cardinalityNext) + batchSize));
            oracle.ORACLE_BASE().increaseObservationCardinalityNext(growTo, oracle.poolId());
            cardinalityNext = growTo;
        }

        // Perform batch updates
        for (uint256 i = 0; i < 1000; i += batchSize) {
            for (uint256 j = 0; j < batchSize && i + j < 1000; j++) {
                oracle.update(OracleTestV4.UpdateParams({advanceTimeBy: 13, tick: -int24(int256(i + j))}));
            }
        }

        // Verify the oracle state
        assertEq(oracle.cardinalityNext(), targetCardinality);
        assertEq(oracle.cardinalityNextBase(), targetCardinality);
        assertEq(oracle.cardinality(), targetCardinality);
        assertEq(oracle.cardinalityBase(), targetCardinality);
        assertEq(oracle.index(), 0);
        assertEq(oracle.indexBase(), 0);
    }

    function test_truncated_full_oracle_setup() public {
        // Initialize oracle
        oracle.initialize(OracleTestV4.InitializeParams({time: uint32(TEST_POOL_START_TIME), tick: 0}));

        // Grow oracle to reasonable size for testing (smaller for truncated tests)
        uint16 cardinalityNext = oracle.cardinalityNextTruncated();
        uint16 targetCardinality = 500; // Smaller for truncated oracle
        uint16 batchSize = 25;
        while (cardinalityNext < targetCardinality) {
            uint16 growTo = uint16(min(uint256(targetCardinality), uint256(cardinalityNext) + batchSize));
            oracle.growTruncated(growTo);
            cardinalityNext = growTo;
        }

        // Perform batch updates (fewer for truncated tests)
        for (uint256 i = 0; i < 500; i += batchSize) {
            for (uint256 j = 0; j < batchSize && i + j < 500; j++) {
                oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 13, tick: -int24(int256(i + j))}));
            }
        }

        // Verify the oracle state
        assertEq(oracle.cardinalityNextTruncated(), 500);
        assertEq(oracle.cardinalityNextBase(), 500);
        assertEq(oracle.cardinalityTruncated(), 500);
        assertEq(oracle.cardinalityBase(), 500);
        assertEq(oracle.indexTruncated(), 0);
        assertEq(oracle.indexBase(), 0);
    }

    function test_truncated_full_oracle_setup_withIncreaseObservationCardinalityNext() public {
        // Initialize oracle
        oracle.initialize(OracleTestV4.InitializeParams({time: uint32(TEST_POOL_START_TIME), tick: 0}));

        // Grow oracle to reasonable size for testing (smaller for truncated tests)
        uint16 cardinalityNext = oracle.cardinalityNextTruncated();
        uint16 targetCardinality = 500; // Smaller for truncated oracle
        uint16 batchSize = 25;
        while (cardinalityNext < targetCardinality) {
            uint16 growTo = uint16(min(uint256(targetCardinality), uint256(cardinalityNext) + batchSize));
            oracle.ORACLE_BASE().increaseObservationCardinalityNext(growTo, oracle.poolId());
            cardinalityNext = growTo;
        }

        // Perform batch updates (fewer for truncated tests)
        for (uint256 i = 0; i < 500; i += batchSize) {
            for (uint256 j = 0; j < batchSize && i + j < 500; j++) {
                oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 13, tick: -int24(int256(i + j))}));
            }
        }

        // Verify the oracle state
        assertEq(oracle.cardinalityNextTruncated(), 500);
        assertEq(oracle.cardinalityNextBase(), 500);
        assertEq(oracle.cardinalityTruncated(), 500);
        assertEq(oracle.cardinalityBase(), 500);
        assertEq(oracle.indexTruncated(), 0);
        assertEq(oracle.indexBase(), 0);
    }

    function test_full_oracle_observe_into_ordered_portion_exact() public {
        test_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 100 * 13;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        assertEq(tickCumulatives[0], -5247463);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -5247463);
    }

    function test_truncated_full_oracle_observe_into_ordered_portion_exact() public {
        test_truncated_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 100 * 13;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        assertEq(tickCumulatives[0], -1032213);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -1032213);
    }

    function test_full_oracle_observe_into_ordered_portion_unexact() public {
        test_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 100 * 13 + 5;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        assertEq(tickCumulatives[0], -5242973);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -5242973);
    }

    function test_truncated_full_oracle_observe_into_ordered_portion_unexact() public {
        test_truncated_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 100 * 13 + 5;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        assertEq(tickCumulatives[0], -1030223);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -1030223);
    }

    function test_full_oracle_observe_at_latest1() public {
        test_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        assertEq(tickCumulatives[0], -6480513);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -6480513);
    }

    function test_truncated_full_oracle_observe_at_latest() public {
        test_truncated_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        assertEq(tickCumulatives[0], -1615263);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -1615263);
    }

    function test_full_oracle_observe_at_latest_after_time() public {
        test_full_oracle_setup();
        oracle.advanceTime(5);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 5;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        assertEq(tickCumulatives[0], -6480513);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -6480513);
    }

    function test_truncated_full_oracle_observe_at_latest_after_time() public {
        test_truncated_full_oracle_setup();
        oracle.advanceTime(5);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 5;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        assertEq(tickCumulatives[0], -1615263);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -1615263);
    }

    function test_observe_after_latest_observation_counterfactual() public {
        test_full_oracle_setup();
        oracle.advanceTime(5);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 3;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], -6482511);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -6482511);
    }

    function test_truncated_observe_after_latest_observation_counterfactual() public {
        test_truncated_full_oracle_setup();
        oracle.advanceTime(5);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 3;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], -1616261);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -1616261);
    }

    function test_observe_into_unordered_portion_exact_seconds() public {
        test_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 200 * 13;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], -4144413);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -4144413);
    }

    function test_truncated_observe_into_unordered_portion_exact_seconds() public {
        test_truncated_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 200 * 13;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], -579163);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -579163);
    }

    function test_observe_into_unordered_portion_between_observations() public {
        test_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 200 * 13 + 5;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], -4140423);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -4140423);
    }

    function test_truncated_observe_into_unordered_portion_between_observations() public {
        test_truncated_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 200 * 13 + 5;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], -577673);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], -577673);
    }

    function test_observe_oldest_observation() public {
        test_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 13 * 999;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 0);
    }

    function test_truncated_observe_oldest_observation() public {
        test_truncated_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 13 * 499;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 0);
    }

    function test_observe_oldest_observation_after_time_elapsed() public {
        test_full_oracle_setup();
        oracle.advanceTime(5);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 13 * 999 + 5;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observe(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (tickCumulatives, /*tickCumulativesTruncated*/ ) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 0);
    }

    function test_truncated_observe_oldest_observation_after_time_elapsed() public {
        test_truncated_full_oracle_setup();

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 13 * 499;
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            oracle.observeTruncated(secondsAgos);

        // Values based on the Hardhat test case
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);

        (, /*tickCumulatives*/ tickCumulatives) = oracle.ORACLE_BASE().observe(secondsAgos, oracle.poolId());

        assertEq(tickCumulatives[0], 0);
    }

    function test_truncated_oracle_tick_behavior_small_move() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 0}));

        oracle.grow(5);

        // Small move within 9116 ticks
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 5000}));
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 0}));

        // Verify both oracles show same tick
        int24 tick = oracle.oracleTick();
        int24 truncatedTick = oracle.truncatedOracleTick();
        assertEq(tick, 5000);
        assertEq(truncatedTick, 5000);
    }

    function test_truncated_oracle_tick_behavior_large_move() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 0}));

        oracle.grow(5);

        // Large move exceeding 9116 ticks
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 10000}));
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 0}));

        // Verify truncated oracle only moved 9116 ticks
        int24 tick = oracle.oracleTick();
        int24 truncatedTick = oracle.truncatedOracleTick();
        assertEq(tick, 10000);
        assertEq(truncatedTick, 9116);
    }

    function test_truncated_oracle_tick_behavior_sequential_moves() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 0}));

        oracle.grow(5);

        // First move: large move exceeding 9116 ticks
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 10000}));

        // Second move: another large move
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 20000}));

        uint256 snap = vm.snapshot();

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 0}));

        // Verify truncated oracle moved in steps of 9116
        int24 tick = oracle.oracleTick();
        int24 truncatedTick = oracle.truncatedOracleTick();
        assertEq(tick, 20000);
        assertEq(truncatedTick, 18232); // 9116 * 2

        vm.revertTo(snap);

        // Third move: small move within 9116 ticks
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 19000}));

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 0}));

        // Verify truncated oracle moved the full amount
        tick = oracle.oracleTick();
        truncatedTick = oracle.truncatedOracleTick();
        assertEq(tick, 19000);
        assertEq(truncatedTick, 19000);
    }

    function test_truncated_oracle_tick_behavior_negative_moves() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 0}));

        oracle.grow(5);

        // Large negative move
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: -10000}));

        uint256 snap = vm.snapshot();

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 0}));

        // Verify truncated oracle only moved -9116 ticks
        int24 tick = oracle.oracleTick();
        int24 truncatedTick = oracle.truncatedOracleTick();
        assertEq(tick, -10000);
        assertEq(truncatedTick, -9116);

        vm.revertTo(snap);

        // Another large negative move
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: -20000}));

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 0}));

        // Verify truncated oracle moved another -9116 ticks
        tick = oracle.oracleTick();
        truncatedTick = oracle.truncatedOracleTick();
        assertEq(tick, -20000);
        assertEq(truncatedTick, -18232); // -9116 * 2
    }

    function test_truncated_oracle_tick_behavior_oscillating_moves() public {
        oracle.initialize(OracleTestV4.InitializeParams({time: 1, tick: 0}));

        oracle.grow(5);

        // Move up beyond limit
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 10000}));

        // Move down beyond limit
        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: -10000}));

        oracle.updateTruncated(OracleTestV4.UpdateParams({advanceTimeBy: 1, tick: 0}));

        // Verify truncated oracle moved in steps
        int24 tick = oracle.oracleTick();
        int24 truncatedTick = oracle.truncatedOracleTick();
        assertEq(tick, -10000);
        assertEq(truncatedTick, 0); // Should be back to 0 after moving -9116 from 9116
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
