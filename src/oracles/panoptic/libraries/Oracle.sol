// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Oracle
/// @notice Provides price data useful for a wide variety of system designs
/// @dev Instances of stored oracle data, "observations", are collected in the oracle array
/// Every pool is initialized with an oracle array length of 1. Anyone can pay the SSTOREs to increase the
/// maximum length of the oracle array. New slots will be added when the array is fully populated.
/// Observations are overwritten when the full length of the oracle array is populated.
/// The most recent observation is available, independent of the length of the oracle array, by passing 0 to observe()
library Oracle {
    /// @notice Thrown when trying to observe a price that is older than the oldest recorded price.
    /// @param oldestTimestamp Timestamp of the oldest remaining observation
    /// @param targetTimestamp Invalid timestamp targeted to be observed
    error TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp);

    /// @notice Type representing a single price observation entry
    /// @param blockTimestamp The block timestamp at which the observation was taken
    /// @param prevTruncatedTick The truncated oracle at the time the last observation was taken
    /// @param tickCumulative The tick accumulator value at the time of the observation, i.e. tick * time elapsed since the pool was first initialized
    /// @param tickCumulativeTruncated The truncated tick accumulator value at the time of the observation, i.e. tick * time (limited by maxAbsTickDelta) elapsed since the pool was first initialized
    /// @param initialized Whether or not the observation is initialized
    struct Observation {
        uint32 blockTimestamp;
        int24 prevTruncatedTick;
        int56 tickCumulative;
        int56 tickCumulativeTruncated;
        bool initialized;
    }

    /// @notice Transforms a previous observation into a new observation, given the passage of time and the current tick.
    /// @dev blockTimestamp _must_ be chronologically equal to or greater than last.blockTimestamp, safe for 0 or 1 overflows.
    /// @param last The specified observation to be transformed
    /// @param blockTimestamp The timestamp of the new observation
    /// @param tick The active tick at the time of the new observation
    /// @param maxAbsTickDelta The maximum absolute tick delta that can be realized in a single block
    /// @return The newly populated observation
    function transform(Observation memory last, uint32 blockTimestamp, int24 tick, int24 maxAbsTickDelta)
        internal
        pure
        returns (Observation memory)
    {
        unchecked {
            int24 truncatedTick = tick;

            int24 tickDelta = tick - last.prevTruncatedTick;

            // optimize for negative case
            if (tickDelta > maxAbsTickDelta || tickDelta < -maxAbsTickDelta) {
                truncatedTick = last.prevTruncatedTick + (tickDelta > 0 ? maxAbsTickDelta : -maxAbsTickDelta);
            }

            uint32 timeDelta = blockTimestamp - last.blockTimestamp;
            return Observation({
                blockTimestamp: blockTimestamp,
                prevTruncatedTick: truncatedTick,
                tickCumulative: last.tickCumulative + int56(tick) * int56(uint56(timeDelta)),
                tickCumulativeTruncated: last.tickCumulativeTruncated + int56(truncatedTick) * int56(uint56(timeDelta)),
                initialized: true
            });
        }
    }

    /// @notice Initialize the oracle array by writing the first slot. Called once for the lifecycle of the observations array.
    /// @param self The stored oracle array
    /// @param time The time of the oracle initialization, via block.timestamp truncated to uint32
    /// @param tick The initial tick
    /// @return The number of populated elements in the oracle array
    /// @return The new length of the oracle array, independent of population
    function initialize(Observation[65535] storage self, uint32 time, int24 tick) internal returns (uint16, uint16) {
        self[0] = Observation({
            blockTimestamp: time,
            prevTruncatedTick: tick,
            tickCumulative: 0,
            tickCumulativeTruncated: 0,
            initialized: true
        });

        return (1, 1);
    }

    /// @notice Writes an oracle observation to the array.
    /// @dev Writable at most once per block. Index represents the most recently written element. cardinality and index must be tracked externally.
    /// If the index is at the end of the allowable array length (according to cardinality), and the next cardinality
    /// is greater than the current one, cardinality may be increased. This restriction is created to preserve ordering.
    /// @param self The stored oracle array
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param blockTimestamp The timestamp of the new observation
    /// @param tick The active tick at the time of the new observation
    /// @param cardinality The number of populated elements in the oracle array
    /// @param cardinalityNext The new length of the oracle array, independent of population
    /// @param maxAbsTickDelta The maximum absolute tick delta that can be realized in a single block with respect to the truncated price
    /// @return indexUpdated The new index of the most recently written element in the oracle array
    /// @return cardinalityUpdated The new cardinality of the oracle array
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint16 cardinality,
        uint16 cardinalityNext,
        int24 maxAbsTickDelta
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        unchecked {
            Observation memory last = self[index];

            // early return if we've already written an observation this block
            if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

            // if the conditions are right, we can bump the cardinality
            if (cardinalityNext > cardinality && index == (cardinality - 1)) {
                cardinalityUpdated = cardinalityNext;
            } else {
                cardinalityUpdated = cardinality;
            }

            indexUpdated = (index + 1) % cardinalityUpdated;
            self[indexUpdated] = transform(last, blockTimestamp, tick, maxAbsTickDelta);
        }
    }

    /// @notice Prepares the oracle array to store up to `next` observations.
    /// @param self The stored oracle array
    /// @param current The current next cardinality of the oracle array
    /// @param next The proposed next cardinality which will be populated in the oracle array
    /// @return next The next cardinality which will be populated in the oracle array
    function grow(Observation[65535] storage self, uint16 current, uint16 next) internal returns (uint16) {
        unchecked {
            // no-op if the passed next value isn't greater than the current next value
            if (next <= current) return current;
            // store in each slot to prevent fresh SSTOREs in swaps
            // this data will not be used because the initialized boolean is still false
            for (; current < next; current++) {
                self[current].blockTimestamp = 1;
            }
            return next;
        }
    }

    /// @notice comparator for 32-bit timestamps.
    /// @dev safe for 0 or 1 overflows, a and b _must_ be chronologically before or equal to time
    /// @param time A timestamp truncated to 32 bits
    /// @param a A comparison timestamp from which to determine the relative position of `time`
    /// @param b From which to determine the relative position of `time`
    /// @return Whether `a` is chronologically <= `b`
    function lte(uint32 time, uint32 a, uint32 b) internal pure returns (bool) {
        unchecked {
            // if there hasn't been overflow, no need to adjust
            if (a <= time && b <= time) return a <= b;

            uint256 aAdjusted = a > time ? a : a + 2 ** 32;
            uint256 bAdjusted = b > time ? b : b + 2 ** 32;

            return aAdjusted <= bAdjusted;
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a target, i.e. where [beforeOrAt, atOrAfter] is satisfied.
    /// The result may be the same observation, or adjacent observations.
    /// @dev The answer must be contained in the array, used when the target is located within the stored observation
    /// boundaries: older than the most recent observation and younger, or the same age as, the oldest observation.
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation recorded before, or at, the target
    /// @return atOrAfter The observation recorded at, or after, the target
    function binarySearch(Observation[65535] storage self, uint32 time, uint32 target, uint16 index, uint16 cardinality)
        internal
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        unchecked {
            uint256 left = (index + 1) % cardinality; // oldest observation
            uint256 right = left + cardinality - 1; // newest observation
            uint256 mid;
            while (true) {
                mid = (left + right) / 2;

                beforeOrAt = self[mid % cardinality];

                // we've landed on an uninitialized tick, keep searching higher (more recently)
                if (!beforeOrAt.initialized) {
                    left = mid + 1;
                    continue;
                }

                atOrAfter = self[(mid + 1) % cardinality];

                bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

                // check if we've found the answer!
                if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp)) break;

                if (!targetAtOrAfter) right = mid - 1;
                else left = mid + 1;
            }
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a given target, i.e. where [beforeOrAt, atOrAfter] is satisfied.
    /// @dev Assumes there is at least 1 initialized observation.
    /// Used by observeSingle() to compute the counterfactual accumulator values as of a given block timestamp.
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param tick The active tick at the time of the returned or simulated observation
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @param maxAbsTickDelta The maximum absolute tick delta that can be realized in a single block with respect to the truncated price
    /// @return beforeOrAt The observation which occurred at, or before, the given timestamp
    /// @return atOrAfter The observation which occurred at, or after, the given timestamp
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint16 cardinality,
        int24 maxAbsTickDelta
    ) internal view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        unchecked {
            // optimistically set before to the newest observation
            beforeOrAt = self[index];

            // if the target is chronologically at or after the newest observation, we can early return
            if (lte(time, beforeOrAt.blockTimestamp, target)) {
                if (beforeOrAt.blockTimestamp == target) {
                    // if newest observation equals target, we're in the same block, so we can ignore atOrAfter
                    return (beforeOrAt, atOrAfter);
                } else {
                    // otherwise, we need to transform
                    return (beforeOrAt, transform(beforeOrAt, target, tick, maxAbsTickDelta));
                }
            }

            // now, set before to the oldest observation
            beforeOrAt = self[(index + 1) % cardinality];
            if (!beforeOrAt.initialized) beforeOrAt = self[0];

            // ensure that the target is chronologically at or after the oldest observation
            if (!lte(time, beforeOrAt.blockTimestamp, target)) {
                revert TargetPredatesOldestObservation(beforeOrAt.blockTimestamp, target);
            }

            // if we've reached this point, we have to binary search
            return binarySearch(self, time, target, index, cardinality);
        }
    }

    /// @notice Returns the price observation as of `secondsAgo` from the given time.
    /// @dev Reverts if an observation at or before the desired observation timestamp does not exist.
    /// 0 may be passed as `secondsAgo' to return the current cumulative values.
    /// If called with a timestamp falling between two observations, returns the counterfactual accumulator values
    /// at exactly the timestamp between the two observations.
    /// @param self The stored oracle array
    /// @param time The current block timestamp
    /// @param secondsAgo The amount of time to look back, in seconds, at which point to return an observation
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @param maxAbsTickDelta The maximum absolute tick delta that can be realized in a single block
    /// @return The tick * time elapsed since the pool was first initialized, as of `secondsAgo`
    /// @return The truncated tick * time elapsed since the pool was first initialized, as of `secondsAgo`
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint16 cardinality,
        int24 maxAbsTickDelta
    ) internal view returns (int56, int56) {
        unchecked {
            if (secondsAgo == 0) {
                Observation memory last = self[index];
                if (last.blockTimestamp != time) {
                    last = transform(last, time, tick, maxAbsTickDelta);
                }
                return (last.tickCumulative, last.tickCumulativeTruncated);
            }

            uint32 target = time - secondsAgo;

            (Observation memory beforeOrAt, Observation memory atOrAfter) =
                getSurroundingObservations(self, time, target, tick, index, cardinality, maxAbsTickDelta);

            if (target == beforeOrAt.blockTimestamp) {
                // we're at the left boundary
                return (beforeOrAt.tickCumulative, beforeOrAt.tickCumulativeTruncated);
            } else if (target == atOrAfter.blockTimestamp) {
                // we're at the right boundary
                return (atOrAfter.tickCumulative, atOrAfter.tickCumulativeTruncated);
            } else {
                // we're in the middle
                uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
                uint32 targetDelta = target - beforeOrAt.blockTimestamp;
                return (
                    beforeOrAt.tickCumulative
                        + ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(uint56(observationTimeDelta)))
                            * int56(uint56(targetDelta)),
                    beforeOrAt.tickCumulativeTruncated
                        + (
                            (atOrAfter.tickCumulativeTruncated - beforeOrAt.tickCumulativeTruncated)
                                / int56(uint56(observationTimeDelta))
                        ) * int56(uint56(targetDelta))
                );
            }
        }
    }

    /// @notice Returns the accumulator values as of each time seconds ago from the given time in the array of `secondsAgos`.
    /// @dev Reverts if `secondsAgos` > oldest observation.
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param secondsAgos Each amount of time to look back, in seconds, at which point to return an observation
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @param maxAbsTickDelta The maximum absolute tick delta that can be realized in a single block with respect to the truncated price
    /// @return tickCumulatives The tick * time elapsed since the pool was first initialized, as of each `secondsAgo`
    /// @return tickCumulativeTruncated The truncated tick * time elapsed since the pool was first initialized, as of each `secondsAgo`
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint16 cardinality,
        int24 maxAbsTickDelta
    ) internal view returns (int56[] memory tickCumulatives, int56[] memory tickCumulativeTruncated) {
        unchecked {
            tickCumulatives = new int56[](secondsAgos.length);
            tickCumulativeTruncated = new int56[](secondsAgos.length);
            for (uint256 i = 0; i < secondsAgos.length; i++) {
                (tickCumulatives[i], tickCumulativeTruncated[i]) =
                    observeSingle(self, time, secondsAgos[i], tick, index, cardinality, maxAbsTickDelta);
            }
        }
    }
}
