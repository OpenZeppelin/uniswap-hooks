// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
// Internal imports
import {BaseDynamicFee} from "../fee/BaseDynamicFee.sol";

contract BaseDynamicFeeMock is BaseDynamicFee, AccessControl {
    bytes32 public constant POKE_ROLE = keccak256("POKE_ROLE");

    constructor(address defaultAdmin, address poker) {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(POKE_ROLE, poker);
    }

    uint24 private _fee;

    function _getFee(PoolKey calldata) internal view override returns (uint24) {
        return _fee;
    }

    function setFee(uint24 fee_) public {
        _fee = fee_;
    }

    /* 
    * @dev Public wrapper that allows an authorized party to update the dynamic LP fee for the given pool
    * using the internal `_poke` function.
    * @param key The pool key to update the dynamic LP fee for.
    */
    function poke(PoolKey calldata key) public onlyRole(POKE_ROLE) {
        _poke(key);
    }

    // Exclude from coverage report
    function test() public {}
}
