// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {LimitOrderHookHandler} from "../../handlers/LimitOrderHook/LimitOrderHookHandler.sol";
import {LimitOrderHookUnrecordedHandler} from "../../handlers/LimitOrderHook/LimitOrderHookUnrecordedHandler.sol";
import {LimitOrderHookInvariantsTest} from "./LimitOrderHookInvariants.t.sol";

/// @dev Campaign for {LimitOrderHook} invariants under swaps the hook does not record. See
/// `LimitOrderHook.invariants.md`.
contract LimitOrderHookUnrecordedInvariantsTest is LimitOrderHookInvariantsTest {
    function _deployHandler(address[] memory actors, int24[] memory ticks)
        internal
        override
        returns (LimitOrderHookHandler)
    {
        return new LimitOrderHookUnrecordedHandler(
            hook,
            manager,
            swapRouter,
            key,
            actors,
            ticks,
            LIQUIDITY_MIN_BOUND,
            LIQUIDITY_MAX_BOUND,
            AMOUNT_MIN_BOUND,
            AMOUNT_MAX_BOUND
        );
    }

    /// @dev A swap only fills against its own direction when it undoes part of an unrecorded move, which
    /// needs order ticks between the two prices.
    function _orderTicks() internal view override returns (int24[] memory ticks) {
        ticks = new int24[](9);
        for (uint256 i; i < ticks.length; ++i) {
            ticks[i] = (int24(int256(i)) - 4) * key.tickSpacing;
        }
    }

    /// @dev An unrecorded swap leaves orders it crossed live, so INV-L-02 does not hold here.
    function invariant_L02_noActiveOrderSurvivesThePriceCrossingIt() public view override {}

    /// @dev An unrecorded swap moves the price away from the recorded tick, so INV-L-03 does not hold here.
    function invariant_L03_recordedTickLowerTracksThePoolTick() public view override {}

    /// @dev Replaces the parent's coverage floors, which the wider tick set does not reach reliably.
    function afterInvariant() public view override {
        LimitOrderHookUnrecordedHandler unrecordedHandler = LimitOrderHookUnrecordedHandler(address(handler));

        console.log("--- STATS ---");
        console.log("unrecordedSwapTo   ", handler.calls("unrecordedSwapTo"));
        console.log("unrecordedExcursion", handler.calls("unrecordedExcursion"));
        console.log("filled             ", handler.ghost_fillCount());
        console.log("swaps moving against their range", unrecordedHandler.ghost_opposedSwaps());
        console.log("fills by those swaps", unrecordedHandler.ghost_opposedFills());

        assertGt(handler.calls("unrecordedSwapTo"), 0, "unrecordedSwapTo was not exercised");
        assertGt(unrecordedHandler.ghost_opposedFills(), 0, "no swap filled against its own direction");
    }
}
