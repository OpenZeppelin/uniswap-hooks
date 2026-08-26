// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @dev Enumerable tick set for invariant-test tick management.
 */
struct TickSet {
    int24[] ticks;
    mapping(int24 => bool) saved;
}

/// @dev A tick was requested from an empty {TickSet}.
error EmptyTickSet();

/// @dev Operations on a {TickSet}.
library LibTickSet {
    /**
     * @dev Adds `tick` to `s`, appending it to `s.ticks`.
     *
     * Does nothing if `tick` is already present, so the set holds no duplicates and a repeated
     * entry never skews seed-based selection towards one tick.
     */
    function add(TickSet storage s, int24 tick) internal {
        if (!s.saved[tick]) {
            s.ticks.push(tick);
            s.saved[tick] = true;
        }
    }

    /// @dev Returns whether `tick` belongs to `s`.
    function contains(TickSet storage s, int24 tick) internal view returns (bool) {
        return s.saved[tick];
    }

    /// @dev Returns the number of ticks in `s`.
    function count(TickSet storage s) internal view returns (uint256) {
        return s.ticks.length;
    }

    /**
     * @dev Returns the tick at position `seed % count(s)`, letting a fuzzer-supplied seed select a
     * tick. The result is deterministic for a given `seed` and set contents.
     *
     * Requirements:
     *
     * - `s` must not be empty.
     */
    function rand(TickSet storage s, uint256 seed) internal view returns (int24) {
        if (s.ticks.length == 0) revert EmptyTickSet();
        return s.ticks[seed % s.ticks.length];
    }
}
