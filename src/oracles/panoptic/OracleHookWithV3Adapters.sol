// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {V3OracleAdapter} from "./adapters/V3OracleAdapter.sol";
import {BaseOracleHook} from "./BaseOracleHook.sol";
import {V3TruncatedOracleAdapter} from "./adapters/V3TruncatedOracleAdapter.sol";

/// @dev A hook that enables a Uniswap V4 pool to record price observations and expose an oracle interface with Uniswap V3-compatible adapters
contract OracleHookWithV3Adapters is BaseOracleHook {
    /// @dev Emitted when adapter contracts are deployed for a pool.
    ///
    /// @param poolId The ID of the pool
    /// @param standardAdapter The address of the standard V3 oracle adapter
    /// @param truncatedAdapter The address of the truncated V3 oracle adapter
    event AdaptersDeployed(PoolId indexed poolId, address standardAdapter, address truncatedAdapter);

    /// @dev Maps pool IDs to their standard V3 oracle adapters
    // solhint-disable-next-line
    mapping(PoolId poolId => address standardAdapter) public standardAdapter;

    /// @dev Maps pool IDs to their truncated V3 oracle adapters
    // solhint-disable-next-line
    mapping(PoolId poolId => address truncatedAdapter) public truncatedAdapter;

    /// @dev Initializes a Uniswap V4 pool with this hook, stores baseline observation state, and optionally performs a cardinality increase.
    ///
    /// @param _maxAbsTickDelta The maximum absolute tick delta that can be observed for the truncated oracle
    constructor(int24 _maxAbsTickDelta) BaseOracleHook(_maxAbsTickDelta) {}

    /// @inheritdoc BaseOracleHook
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        IPoolManager poolManager = poolManager();

        // Deploy adapter contracts
        V3OracleAdapter _standardAdapter = new V3OracleAdapter(poolManager, this, poolId);
        V3TruncatedOracleAdapter _truncatedAdapter = new V3TruncatedOracleAdapter(poolManager, this, poolId);

        // Store adapter addresses
        standardAdapter[poolId] = address(_standardAdapter);
        truncatedAdapter[poolId] = address(_truncatedAdapter);

        // Emit event for adapter deployment
        emit AdaptersDeployed(poolId, address(_standardAdapter), address(_truncatedAdapter));

        return super._afterInitialize(address(0), key, 0, tick);
    }
}
