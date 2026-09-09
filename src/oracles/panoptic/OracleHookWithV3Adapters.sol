// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// External
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// Internal
import {V3OracleAdapter} from "./adapters/V3OracleAdapter.sol";
import {BaseOracleHook} from "./BaseOracleHook.sol";
import {V3TruncatedOracleAdapter} from "./adapters/V3TruncatedOracleAdapter.sol";

/// @dev A hook that enables a Uniswap V4 pool to record price observations and expose an oracle interface with Uniswap V3-compatible adapters
abstract contract OracleHookWithV3Adapters is BaseOracleHook {
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

    /// @dev The hook called after the state of a pool is initialized
    ///
    /// WARNING: Pool initialization is permissionless, so anyone can initialize a pool that references this hook and
    /// force it to deploy a pair of adapters. The caller pays for the deployment, and each pair serves only its own
    /// pool, so other pools are unaffected. To limit which pools this hook serves, set `beforeInitialize` in
    /// `getHookPermissions` and override `_beforeInitialize` to reject unwanted keys.
    ///
    /// @param key The key for the pool being initialized
    /// @return bytes4 The function selector for the hook
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();

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
