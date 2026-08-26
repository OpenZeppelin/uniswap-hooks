// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev The tick and direction an order id was created for.
struct OrderKey {
    int24 tickLower;
    bool zeroForOne;
}

/**
 * @dev Enumerable order id set for `LimitOrderHook` invariant tests.
 *
 * The hook erases an order id from its own mapping once the order fills or its last liquidity is
 * cancelled, and it never stores the reverse direction from id back to tick and direction. Holding
 * both here keeps retired orders reachable, which is where several invariants look for stranded
 * currency.
 */
struct OrderIdSet {
    uint232[] ids;
    mapping(uint232 => bool) saved;
    mapping(uint232 => OrderKey) keys;
}

/// @dev An order id was requested from an empty {OrderIdSet}.
error EmptyOrderIdSet();

/// @dev A key was requested for an order id the set does not hold.
error UnknownOrderId(uint232 id);

/// @dev Operations on an {OrderIdSet}.
library LibOrderIdSet {
    /**
     * @dev Adds `id` to `s` along with the `key` it was created for, appending it to `s.ids`.
     *
     * Does nothing if `id` is already present or is the default order id, so the set holds no
     * duplicates and never holds the sentinel the hook uses for "no order".
     */
    function add(OrderIdSet storage s, uint232 id, OrderKey memory key) internal {
        if (id != 0 && !s.saved[id]) {
            s.ids.push(id);
            s.saved[id] = true;
            s.keys[id] = key;
        }
    }

    /// @dev Returns whether `id` belongs to `s`.
    function contains(OrderIdSet storage s, uint232 id) internal view returns (bool) {
        return s.saved[id];
    }

    /// @dev Returns the number of order ids in `s`.
    function count(OrderIdSet storage s) internal view returns (uint256) {
        return s.ids.length;
    }

    /**
     * @dev Returns the tick and direction `id` was created for.
     *
     * Reverts rather than returning a zeroed key, since `(0, false)` is a plausible key and would
     * send an invariant looking at the wrong tick.
     *
     * Requirements:
     *
     * - `id` must belong to `s`.
     */
    function keyOf(OrderIdSet storage s, uint232 id) internal view returns (OrderKey memory) {
        if (!s.saved[id]) revert UnknownOrderId(id);
        return s.keys[id];
    }

    /**
     * @dev Returns the order id at position `seed % count(s)`, letting a fuzzer-supplied seed select
     * an order. The result is deterministic for a given `seed` and set contents.
     *
     * Requirements:
     *
     * - `s` must not be empty.
     */
    function rand(OrderIdSet storage s, uint256 seed) internal view returns (uint232) {
        if (s.ids.length == 0) revert EmptyOrderIdSet();
        return s.ids[seed % s.ids.length];
    }
}
