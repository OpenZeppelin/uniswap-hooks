// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AddressSet, LibAddressSet} from "../helpers/AddressSet.sol";
import {TickSet, LibTickSet} from "../helpers/TickSet.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/**
 * @dev Shared state for managed (handler-based) invariant testing.
 */
abstract contract BaseHandler is Test {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // --------------- State --------------- //

    IPoolManager public manager;
    PoolSwapTest public swapRouter;
    PoolKey public key;
    PoolId public poolId;

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

    /// @dev Pick an actor from a fuzzer seed. Requires at least one registered actor.
    function _actorFromSeed(uint256 seed) internal virtual returns (address) {
        return _actors.rand(seed);
    }

    /// @dev Returns the addresses of the actors.
    function actors() public view returns (address[] memory) {
        return _actors.addrs;
    }

    /// @dev Returns the number of actors.
    function actorCount() public view returns (uint256) {
        return _actors.count();
    }

    // --------------- Ticks --------------- //

    using LibTickSet for TickSet;

    /// @dev Bounded set of ticks the fuzzer can target.
    TickSet internal _ticks;

    /// @dev Register ticks for the fuzzer to target.
    function _createTicks(int24[] memory ticks_) internal {
        for (uint256 i; i < ticks_.length; ++i) {
            _createTick(ticks_[i]);
        }
    }

    /// @dev Register a tick for the fuzzer to target.
    function _createTick(int24 tick) internal {
        _ticks.add(tick);
    }

    /// @dev Pick a tick from a fuzzer seed. Requires at least one registered tick.
    function _tickFromSeed(uint256 seed) internal view returns (int24) {
        return _ticks.rand(seed);
    }

    /// @dev Returns the registered ticks.
    function ticks() public view returns (int24[] memory) {
        return _ticks.ticks;
    }

    /// @dev Returns the number of registered ticks.
    function tickCount() public view returns (uint256) {
        return _ticks.count();
    }

    // --------------- Calls --------------- //

    /// @dev Action name => number of calls that reached the target.
    mapping(bytes32 => uint256) public calls;

    /// @dev Record an action that reached the target.
    function _recordCall(bytes32 name) internal {
        calls[name]++;
    }

    /// @dev Record an action that reached the target.
    modifier recordCall(bytes32 name) {
        _;
        _recordCall(name);
    }

    // --------------- Utils --------------- //

    /// @dev Returns the balance of a currency for an address.
    function _balanceOf(Currency currency, address who) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(who);
    }

    /// @dev ERC-6909 claim balance `who` holds in the `PoolManager` for `currency`.
    function _claimsOf(Currency currency, address who) internal view returns (uint256) {
        return IERC6909Claims(address(manager)).balanceOf(who, currency.toId());
    }

    /// @dev Returns the ERC-6909 claim balance `who` holds in the `PoolManager` for `currency`.
    function claimsOf(Currency currency, address who) public view returns (uint256) {
        return _claimsOf(currency, who);
    }

    /// @dev Current tick of the pool.
    function _currentTick() internal view returns (int24) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @dev Current tick rounded down to a multiple of `tickSpacing`, towards negative infinity.
    function _currentTickLower() internal view returns (int24) {
        return _floorToSpacing(_currentTick());
    }

    /// @dev Tick the pool stores in `slot0`, which is what `modifyLiquidity` branches on. A swap going
    /// down sets it to `tickNext - 1` when it lands on an initialized tick, so it is not always the tick
    /// the price maps to. Reading it keeps an assertion independent of the hook's own derivation.
    function _storedTick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }

    /// @dev `_storedTick` rounded down to a multiple of `tickSpacing`, towards negative infinity.
    function _storedTickLower() internal view returns (int24) {
        return _floorToSpacing(_storedTick());
    }

    /// @dev Rounds `tick` down to a multiple of `tickSpacing`, towards negative infinity.
    function _floorToSpacing(int24 tick) private view returns (int24) {
        int24 compressed = tick / key.tickSpacing;
        if (tick < 0 && tick % key.tickSpacing != 0) compressed--;

        return compressed * key.tickSpacing;
    }

    /// @dev Current tick of the pool.
    function currentTick() public view returns (int24) {
        return _currentTick();
    }

    /// @dev Current tick lower of the pool.
    function currentTickLower() public view returns (int24) {
        return _currentTickLower();
    }

    /// @dev Tick the pool stores in `slot0`.
    function storedTick() public view returns (int24) {
        return _storedTick();
    }

    /// @dev Tick the pool stores in `slot0`, rounded down to a multiple of `tickSpacing`.
    function storedTickLower() public view returns (int24) {
        return _storedTickLower();
    }

    /// @dev Swap up to `amount` in through the router, stopping at `tickLimit`.
    function _swap(bool zeroForOne, uint256 amount, int24 tickLimit) internal virtual {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLimit)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
