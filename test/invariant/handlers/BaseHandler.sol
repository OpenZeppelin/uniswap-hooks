// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AddressSet, LibAddressSet} from "../helpers/AddressSet.sol";
import {TickSet, LibTickSet} from "../helpers/TickSet.sol";

/**
 * @dev Shared state for managed (handler-based) invariant testing.
 */
abstract contract BaseHandler is Test {
    // --------------- Actors --------------- //

    using LibAddressSet for AddressSet;

    /// @dev Bounded set of actors the fuzzer can act as.
    AddressSet internal _actors;

    /// @dev Register `actors_` as actors the fuzzer can act as.
    function _createActors(address[] memory actors_) internal {
        for (uint256 i; i < actors_.length; ++i) {
            _createActor(actors_[i]);
        }
    }

    /// @dev Register an actor for the fuzzer to act as.
    function _createActor(address actor) internal {
        _actors.add(actor);
    }

    /// @dev Pick an actor from a fuzzer seed.
    /// NOTE: at least one actor must be registered.
    function _actorFromSeed(uint256 seed) internal view returns (address) {
        return _actors.rand(seed);
    }

    /// @dev Returns the addresses of the actors.
    function actors() external view returns (address[] memory) {
        return _actors.addrs;
    }

    /// @dev Returns the number of actors.
    function actorCount() external view returns (uint256) {
        return _actors.count();
    }

    // --------------- Ticks --------------- //

    using LibTickSet for TickSet;

    /// @dev Bounded set of ticks the fuzzer can target.
    TickSet internal _ticks;

    /// @dev Register `ticks_` as ticks the fuzzer can target.
    function _createTicks(int24[] memory ticks_) internal {
        for (uint256 i; i < ticks_.length; ++i) {
            _createTick(ticks_[i]);
        }
    }

    /// @dev Register a tick for the fuzzer to target.
    function _createTick(int24 tick) internal {
        _ticks.add(tick);
    }

    /// @dev Pick a tick from a fuzzer seed.
    /// NOTE: at least one tick must be registered.
    function _tickFromSeed(uint256 seed) internal view returns (int24) {
        return _ticks.rand(seed);
    }

    /// @dev Returns the registered ticks.
    function ticks() external view returns (int24[] memory) {
        return _ticks.ticks;
    }

    /// @dev Returns the number of ticks.
    function tickCount() external view returns (uint256) {
        return _ticks.count();
    }

    // --------------- Calls --------------- //

    /// @dev Action name => number of calls that reached the target.
    mapping(bytes32 => uint256) public calls;

    /// @dev Record an action that reached the target.
    function _recordCall(bytes32 name) internal {
        calls[name]++;
    }
}
