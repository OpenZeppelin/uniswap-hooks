// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @dev Enumerable address set for invariant-test actor management.
 */
struct AddressSet {
    address[] addrs;
    mapping(address => bool) saved;
}

/// @dev An actor was requested from an empty {AddressSet}.
error EmptyAddressSet();

/// @dev Operations on an {AddressSet}.
library LibAddressSet {
    /**
     * @dev Adds `addr` to `s`, appending it to `s.addrs`.
     *
     * Does nothing if `addr` is already present, so the set holds no duplicates and an address
     * counted once in an invariant is never counted twice.
     */
    function add(AddressSet storage s, address addr) internal {
        if (!s.saved[addr]) {
            s.addrs.push(addr);
            s.saved[addr] = true;
        }
    }

    /// @dev Returns whether `addr` belongs to `s`.
    function contains(AddressSet storage s, address addr) internal view returns (bool) {
        return s.saved[addr];
    }

    /// @dev Returns the number of addresses in `s`.
    function count(AddressSet storage s) internal view returns (uint256) {
        return s.addrs.length;
    }

    /**
     * @dev Returns the address at position `seed % count(s)`, letting a fuzzer-supplied seed select
     * an actor. The result is deterministic for a given `seed` and set contents.
     *
     * Requirements:
     *
     * - `s` must not be empty.
     */
    function rand(AddressSet storage s, uint256 seed) internal view returns (address) {
        if (s.addrs.length == 0) revert EmptyAddressSet();
        return s.addrs[seed % s.addrs.length];
    }
}
