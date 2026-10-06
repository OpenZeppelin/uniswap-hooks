// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// External imports
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
// Internal imports
import {
    ReHypothecationERC4626Mock,
    ERC4626YieldSourceMock
} from "../../src/mocks/general/ReHypothecationERC4626Mock.sol";
import {ReHypothecationHook} from "../../src/general/ReHypothecationHook.sol";
import {ERC20RejectZeroTransferMock} from "../../src/mocks/general/ERC20RejectZeroTransferMock.sol";
import {HookTest} from "../utils/HookTest.sol";
import {BalanceDeltaAssertions} from "../utils/BalanceDeltaAssertions.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";

/// @dev An ERC-4626 yield source whose `maxWithdraw` can be capped below its balance, to model gated or
/// illiquid vaults when testing the withdrawable-based JIT sizing. Uncapped, it behaves like its parent.
contract CappedERC4626Mock is ERC4626YieldSourceMock {
    uint256 private _cap = type(uint256).max;

    constructor(IERC20 token) ERC4626YieldSourceMock(token) {}

    function setCap(uint256 cap) external {
        _cap = cap;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 unconstrained = super.maxWithdraw(owner);
        return unconstrained < _cap ? unconstrained : _cap;
    }
}

/// @dev An ERC-4626 yield source that reverts on zero-amount deposits/withdrawals, like several real lending
/// protocols, to test that the hook skips zero-amount yield-source calls.
contract RevertOnZeroERC4626Mock is ERC4626YieldSourceMock {
    error ZeroAmount();

    constructor(IERC20 token) ERC4626YieldSourceMock(token) {}

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        return super.deposit(assets, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        return super.withdraw(assets, receiver, owner);
    }
}

/// @dev A rehypothecation hook whose position range tracks the current pool tick, so the range shifts as a swap
/// moves the price. Used to test that the position's tick bounds are snapshotted across a swap.
contract DynamicTickReHypothecationMock is ReHypothecationERC4626Mock {
    using StateLibrary for IPoolManager;

    constructor(IPoolManager pm, address ys0, address ys1) ReHypothecationERC4626Mock(pm, ys0, ys1) {}

    function getTickLower() public view override returns (int24) {
        return _center() - 10 * getPoolKey().tickSpacing;
    }

    function getTickUpper() public view override returns (int24) {
        return _center() + 10 * getPoolKey().tickSpacing;
    }

    function _center() private view returns (int24) {
        (, int24 tick,,) = poolManager.getSlot0(getPoolKey().toId());
        int24 spacing = getPoolKey().tickSpacing;
        return (tick / spacing) * spacing;
    }
}

/// @dev A rehypothecation hook whose position range is fixed at construction, to test JIT sizing on narrow ranges.
contract FixedRangeReHypothecationMock is ReHypothecationERC4626Mock {
    int24 private immutable _tickLower;
    int24 private immutable _tickUpper;

    constructor(IPoolManager pm, address ys0, address ys1, int24 tickLower_, int24 tickUpper_)
        ReHypothecationERC4626Mock(pm, ys0, ys1)
    {
        _tickLower = tickLower_;
        _tickUpper = tickUpper_;
    }

    function getTickLower() public view override returns (int24) {
        return _tickLower;
    }

    function getTickUpper() public view override returns (int24) {
        return _tickUpper;
    }
}

/// @dev A yield source that attempts to reenter the hook's `removeReHypothecatedLiquidity` on withdraw, to
/// test that liquidity operations are locked during a swap's settlement.
contract ReentrantYieldSourceMock is ERC4626YieldSourceMock {
    ReHypothecationHook public hook;
    bool public reentered;
    bytes public reentryRevertReason;
    bool private _armed;

    constructor(IERC20 token) ERC4626YieldSourceMock(token) {}

    function arm(ReHypothecationHook hook_) external {
        hook = hook_;
        _armed = true;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (_armed) {
            _armed = false;
            reentered = true;
            try hook.removeReHypothecatedLiquidity(1, 0, 0) {}
            catch (bytes memory reason) {
                reentryRevertReason = reason;
            }
        }
        return super.withdraw(assets, receiver, owner);
    }
}

/// @dev A hook that only accepts a pool with a specific fee, exercising the `_beforeInitialize` override.
contract ValidatingReHypothecationMock is ReHypothecationERC4626Mock {
    error WrongPool();

    constructor(IPoolManager pm, address ys0, address ys1) ReHypothecationERC4626Mock(pm, ys0, ys1) {}

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        if (key.fee != 3000) revert WrongPool();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }
}

contract ReHypothecationHookERC4626Test is HookTest, BalanceDeltaAssertions {
    using StateLibrary for IPoolManager;
    using SafeCast for *;
    using Math for *;

    ReHypothecationERC4626Mock hook;

    CappedERC4626Mock yieldSource0;
    CappedERC4626Mock yieldSource1;

    PoolKey noHookKey;

    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");

    uint24 fee = 1000; // 0.1%

    /// @dev Amount used to seed each currency; at price 1:1 this mints `sqrt(SEED * SEED) == SEED` shares.
    uint256 constant SEED = 1e18;
    uint256 constant SEED_SHARES = SEED;

    /// @dev Absolute tolerance covering the EIP-4626 style virtual offset and rounding (offset is 1e6).
    uint256 constant TOL = 1e9;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        yieldSource0 = new CappedERC4626Mock(IERC20(Currency.unwrap(currency0)));
        yieldSource1 = new CappedERC4626Mock(IERC20(Currency.unwrap(currency1)));

        hook = ReHypothecationERC4626Mock(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    )
                ))
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(hook)
        );

        (key,) = initPool(currency0, currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
        (noHookKey,) = initPool(currency0, currency1, IHooks(address(0)), fee, SQRT_PRICE_1_1);

        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");

        _fund([address(manager), address(this), lp1, lp2], [currency0, currency1], 1e30);

        _approveCurrencies(
            [address(this), lp1, lp2],
            [currency0, currency1],
            [address(manager), address(hook), address(swapRouter), address(modifyLiquidityRouter)]
        );
    }

    function _fund(address[4] memory addresses, Currency[2] memory currencies, uint256 amount) internal {
        for (uint256 i = 0; i < addresses.length; i++) {
            for (uint256 j = 0; j < currencies.length; j++) {
                deal(Currency.unwrap(currencies[j]), addresses[i], amount);
            }
        }
    }

    function _approveCurrencies(address[3] memory approvers, Currency[2] memory currencies, address[4] memory spenders)
        internal
    {
        // make `approvers` approve `currencies` to `spenders`
        for (uint256 i = 0; i < approvers.length; i++) {
            vm.startPrank(approvers[i]);
            for (uint256 j = 0; j < currencies.length; j++) {
                for (uint256 k = 0; k < spenders.length; k++) {
                    IERC20(Currency.unwrap(currencies[j])).approve(spenders[k], type(uint256).max);
                }
            }
            vm.stopPrank();
        }
    }

    /// @dev Seeds the pool (from `who`) with `SEED` of each currency, minting `SEED_SHARES` shares.
    function _seedBy(address who) internal returns (uint256 shares) {
        vm.prank(who);
        (shares,) = hook.seedLiquidity(SEED, SEED);
    }

    function _seed() internal returns (uint256 shares) {
        (shares,) = hook.seedLiquidity(SEED, SEED);
    }

    /// @dev A distinct hook address carrying the required permission flag bits, offset by `nudge`.
    function _flagAddr(uint160 nudge) internal pure returns (address) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        return address(flags + nudge);
    }

    // -- INITIALIZING -- //

    function test_initialize_already_initialized_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook), // target
                bytes4(BaseHook.beforeInitialize.selector), // selector (beforeInitialize)
                abi.encodeWithSelector(ReHypothecationHook.AlreadyInitialized.selector), // reason
                hex"a9e35b2f" // details
            )
        );
        initPool(currency0, currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
    }

    function test_initialize_native_currency_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(ReHypothecationERC4626Mock.UnsupportedCurrency.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        initPool(Currency.wrap(address(0)), currency1, IHooks(address(hook)), fee, SQRT_PRICE_1_1);
    }

    // -- EXTERNAL LIQUIDITY BLOCKED -- //

    function test_hookPermissions_blockLiquidity() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeAddLiquidity, "beforeAddLiquidity should be enabled");
        assertTrue(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity should be enabled");
    }

    function test_external_addLiquidity_reverts() public {
        // Cache tick reads so `expectRevert` binds to the router call, not the getter sub-calls.
        int24 tickLower = hook.getTickLower();
        int24 tickUpper = hook.getTickUpper();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ReHypothecationHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyPoolLiquidity(key, tickLower, tickUpper, int256(1e18), 0);
    }

    function test_external_removeLiquidity_reverts() public {
        // Cache tick reads so `expectRevert` binds to the router call, not the getter sub-calls.
        int24 tickLower = hook.getTickLower();
        int24 tickUpper = hook.getTickUpper();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(ReHypothecationHook.LiquidityNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyPoolLiquidity(key, tickLower, tickUpper, -int256(1e18), 0);
    }

    // -- SEEDING -- //

    function test_seed_uninitialized_reverts() public {
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        ReHypothecationERC4626Mock newHook = ReHypothecationERC4626Mock(
            payable(address(hookFlags + 0x10000000000000000000000000000000)) // generate a different address
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );
        vm.expectRevert(ReHypothecationHook.NotInitialized.selector);
        newHook.seedLiquidity(SEED, SEED);
    }

    function test_seed_alreadySeeded_reverts() public {
        _seed();
        vm.expectRevert(ReHypothecationHook.AlreadySeeded.selector);
        hook.seedLiquidity(SEED, SEED);
    }

    function test_seed_belowFloor_reverts() public {
        // sqrt(1000 * 1000) == 1000, below the 100 * 10**6 floor.
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationHook.InsufficientSeed.selector, 1000, 100_000_000));
        hook.seedLiquidity(1000, 1000);
    }

    function test_seed_mintsSqrtShares() public {
        uint256 amount0 = 4e18;
        uint256 amount1 = 1e18;

        uint256 lpAmount0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 lpAmount1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        (uint256 shares, BalanceDelta delta) = hook.seedLiquidity(amount0, amount1);

        // shares are the geometric mean of the seeded amounts
        assertEq(shares, Math.sqrt(amount0 * amount1), "shares != sqrt(amount0 * amount1)");
        assertEq(shares, 2e18, "shares != 2e18");
        assertEq(hook.balanceOf(address(this)), shares, "balance != shares");
        assertEq(hook.totalSupply(), shares, "totalSupply != shares");

        // the seeded amounts were pulled and deposited into the yield sources
        assertEq((-delta.amount0()).toUint256(), amount0, "delta.amount0() != amount0");
        assertEq((-delta.amount1()).toUint256(), amount1, "delta.amount1() != amount1");
        assertEq(lpAmount0Before - IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), amount0);
        assertEq(lpAmount1Before - IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), amount1);
        assertEq(hook.getAmountInYieldSource(currency0), amount0, "yieldSource0 != amount0");
        assertEq(hook.getAmountInYieldSource(currency1), amount1, "yieldSource1 != amount1");
    }

    // -- ADDING -- //

    function test_add_uninitialized_reverts() public {
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        ReHypothecationERC4626Mock newHook = ReHypothecationERC4626Mock(
            payable(address(hookFlags + 0x10000000000000000000000000000000)) // generate a different address
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );
        vm.expectRevert(ReHypothecationHook.NotInitialized.selector);
        newHook.addReHypothecatedLiquidity(1e15, type(uint256).max, type(uint256).max);
    }

    function test_add_notSeeded_reverts() public {
        vm.expectRevert(ReHypothecationHook.NotSeeded.selector);
        hook.addReHypothecatedLiquidity(1e15, type(uint256).max, type(uint256).max);
    }

    function test_add_withinBounds_succeeds() public {
        _seed();
        (uint256 amount0, uint256 amount1) = hook.previewMint(1e17);

        BalanceDelta delta = hook.addReHypothecatedLiquidity(1e17, amount0, amount1);

        assertEq((-delta.amount0()).toUint256(), amount0);
        assertEq((-delta.amount1()).toUint256(), amount1);
        assertEq(hook.balanceOf(address(this)), SEED_SHARES + 1e17);
    }

    function test_add_exceedsBound_reverts() public {
        _seed();
        (uint256 amount0, uint256 amount1) = hook.previewMint(1e17);

        vm.expectRevert(ReHypothecationHook.TooMuchSlippage.selector);
        hook.addReHypothecatedLiquidity(1e17, amount0 - 1, amount1);

        vm.expectRevert(ReHypothecationHook.TooMuchSlippage.selector);
        hook.addReHypothecatedLiquidity(1e17, amount0, amount1 - 1);
    }

    function test_add_sandwiched_reverts() public {
        _seed();
        (uint256 amount0, uint256 amount1) = hook.previewMint(5e17);

        // a swap before the mint skews the balances and raises the required input
        vm.prank(lp2);
        swap(key, true, -3e17, ZERO_BYTES);

        vm.prank(lp1);
        vm.expectRevert(ReHypothecationHook.TooMuchSlippage.selector);
        hook.addReHypothecatedLiquidity(5e17, amount0, amount1);
    }

    function test_add_zero_reverts() public {
        _seed();
        vm.expectRevert(ReHypothecationHook.ZeroShares.selector);
        hook.addReHypothecatedLiquidity(0, type(uint256).max, type(uint256).max);
    }

    function testFuzz_add_singleLP(uint128 shares) public {
        shares = uint128(bound(shares, 1e12, 1e20));

        // Seed the pool from a different LP so the tested `add` runs against a live pool.
        _seedBy(lp1);

        uint256 lpAmount0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 lpAmount1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amount0InYieldSource0Before = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource1Before = hook.getAmountInYieldSource(currency1);

        (uint256 previewedAmount0, uint256 previewedAmount1) = hook.previewMint(shares);

        BalanceDelta delta = hook.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);

        assertEq((-delta.amount0()).toUint256(), previewedAmount0, "Delta.amount0() != amount0");
        assertEq((-delta.amount1()).toUint256(), previewedAmount1, "Delta.amount1() != amount1");

        uint256 lpAmount0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 lpAmount1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amount0InYieldSource0After = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource1After = hook.getAmountInYieldSource(currency1);

        assertEq(lpAmount0After, lpAmount0Before - previewedAmount0, "lpAmount0After != lpAmount0Before - amount0");
        assertEq(lpAmount1After, lpAmount1Before - previewedAmount1, "lpAmount1After != lpAmount1Before - amount1");

        assertEq(
            amount0InYieldSource0After,
            amount0InYieldSource0Before + previewedAmount0,
            "Amount0InYieldSource0After != Amount0InYieldSource0Before + Amount0"
        );
        assertEq(
            amount1InYieldSource1After,
            amount1InYieldSource1Before + previewedAmount1,
            "amount1InYieldSource1After != amount1InYieldSource1Before + amount1"
        );

        assertEq(hook.balanceOf(address(this)), shares, "obtained shares != shares");
    }

    function test_add_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        // lp1 seeds the pool (minting SEED_SHARES), then adds like lp2.
        _seedBy(lp1);

        vm.prank(lp1);
        BalanceDelta addDeltalp1 = hook.addReHypothecatedLiquidity(shareslp1, type(uint256).max, type(uint256).max);

        vm.prank(lp2);
        BalanceDelta addDeltalp2 = hook.addReHypothecatedLiquidity(shareslp2, type(uint256).max, type(uint256).max);

        // both add the same shares against the same state, so pay the same amount of assets
        assertApproxEqAbs(addDeltalp1, addDeltalp2, TOL);

        // lp1 additionally holds the seed shares
        assertEq(hook.balanceOf(lp1), SEED_SHARES + shareslp1);
        assertEq(hook.balanceOf(lp2), shareslp2);

        // total supply should be the sum of the seed and both adds
        assertEq(hook.totalSupply(), SEED_SHARES + shareslp1 + shareslp2);
    }

    function test_add_swap_add_multipleLP() public {
        // both lps want equal amount of shares
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        _seed();

        vm.prank(lp1);
        BalanceDelta addDeltalp1 = hook.addReHypothecatedLiquidity(shareslp1, type(uint256).max, type(uint256).max);

        swap(key, true, 1e15, ZERO_BYTES);
        // perform another swap to rebalance the pool
        swap(key, false, 1e15 + 1e10, ZERO_BYTES);

        vm.prank(lp2);
        BalanceDelta addDeltalp2 = hook.addReHypothecatedLiquidity(shareslp2, type(uint256).max, type(uint256).max);

        // both must have received the same amount of shares
        assertEq(hook.balanceOf(lp1), hook.balanceOf(lp2));

        // lp2 must have deposited more assets than lp1 to achieve the same shares
        assertGt(-addDeltalp2.amount0(), -addDeltalp1.amount0());
        assertGt(-addDeltalp2.amount1(), -addDeltalp1.amount1());

        // total supply should be the sum of the seed and both adds
        assertEq(hook.totalSupply(), SEED_SHARES + shareslp1 + shareslp2);
    }

    function test_add_yieldsGrowth_add_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        // lp1 seeds the pool, so at this point pile == supply == SEED_SHARES.
        _seedBy(lp1);

        BalanceDelta addDeltalp1;
        {
            uint256 amount0Before = hook.getAmountInYieldSource(currency0);
            uint256 amount1Before = hook.getAmountInYieldSource(currency1);
            vm.prank(lp2);
            addDeltalp1 = hook.addReHypothecatedLiquidity(shareslp1, type(uint256).max, type(uint256).max);
            // capture how much lp1-equivalent (lp2) paid against the seeded pile
            amount0Before;
            amount1Before;
        }

        uint256 amount0InYieldSource = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource = hook.getAmountInYieldSource(currency1);

        // yield0 grows by 10%
        currency0.transfer(address(yieldSource0), amount0InYieldSource * 10 / 100);
        // yield1 grows by 20%
        currency1.transfer(address(yieldSource1), amount1InYieldSource * 20 / 100);

        vm.prank(lp2);
        BalanceDelta addDeltalp2 = hook.addReHypothecatedLiquidity(shareslp2, type(uint256).max, type(uint256).max);

        // in order to obtain the same shares as the first add, the second add pays 10% more currency0
        // and 20% more currency1
        assertApproxEqAbs(-addDeltalp2.amount0(), -addDeltalp1.amount0() * 110 / 100, TOL);
        assertApproxEqAbs(-addDeltalp2.amount1(), -addDeltalp1.amount1() * 120 / 100, TOL);

        // total supply should be the sum of the seed and both adds
        assertEq(hook.totalSupply(), SEED_SHARES + shareslp1 + shareslp2);
    }

    function test_add_yieldsDecay_add_multipleLP() public {
        uint128 shareslp1 = 1e18;
        uint128 shareslp2 = 1e18;

        _seedBy(lp1);

        vm.prank(lp2);
        BalanceDelta addDeltalp1 = hook.addReHypothecatedLiquidity(shareslp1, type(uint256).max, type(uint256).max);

        uint256 amount0InYieldSource = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource = hook.getAmountInYieldSource(currency1);

        // yield0 decays by 10%
        hook.burnYieldSourcesBalance(currency0, amount0InYieldSource * 10 / 100);
        // yield1 decays by 20%
        hook.burnYieldSourcesBalance(currency1, amount1InYieldSource * 20 / 100);

        vm.prank(lp2);
        BalanceDelta addDeltalp2 = hook.addReHypothecatedLiquidity(shareslp2, type(uint256).max, type(uint256).max);

        // in order to obtain the same shares as the first add, the second add pays 10% less currency0
        // and 20% less currency1
        assertApproxEqAbs(-addDeltalp2.amount0(), -addDeltalp1.amount0() * 90 / 100, TOL);
        assertApproxEqAbs(-addDeltalp2.amount1(), -addDeltalp1.amount1() * 80 / 100, TOL);

        // total supply should be the sum of the seed and both adds
        assertEq(hook.totalSupply(), SEED_SHARES + shareslp1 + shareslp2);
    }

    // -- REMOVING -- //

    function test_remove_uninitialized_reverts() public {
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        ReHypothecationERC4626Mock newHook = ReHypothecationERC4626Mock(
            payable(address(hookFlags + 0x10000000000000000000000000000000)) // generate a different address
        );
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(yieldSource0), address(yieldSource1)),
            address(newHook)
        );
        vm.expectRevert(ReHypothecationHook.NotInitialized.selector);
        newHook.removeReHypothecatedLiquidity(1e15, 0, 0);
    }

    function test_remove_aboveBound_succeeds() public {
        _seed();
        (uint256 amount0, uint256 amount1) = hook.previewRedeem(1e17);

        BalanceDelta delta = hook.removeReHypothecatedLiquidity(1e17, amount0, amount1);

        assertEq(delta.amount0().toUint256(), amount0);
        assertEq(delta.amount1().toUint256(), amount1);
    }

    function test_remove_belowBound_reverts() public {
        _seed();
        (uint256 amount0, uint256 amount1) = hook.previewRedeem(1e17);

        vm.expectRevert(ReHypothecationHook.TooMuchSlippage.selector);
        hook.removeReHypothecatedLiquidity(1e17, amount0 + 1, amount1);

        vm.expectRevert(ReHypothecationHook.TooMuchSlippage.selector);
        hook.removeReHypothecatedLiquidity(1e17, amount0, amount1 + 1);
    }

    function test_remove_zero_reverts() public {
        vm.expectRevert(ReHypothecationHook.ZeroShares.selector);
        hook.removeReHypothecatedLiquidity(0, 0, 0);
    }

    function testFuzz_remove_singleLP(uint128 shares) public {
        shares = uint128(bound(shares, 1e12, 1e20));

        // Seed such that the caller ends up holding exactly `shares` shares.
        (, BalanceDelta addDelta) = hook.seedLiquidity(shares, shares);

        uint256 lpAmount0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 lpAmount1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amount0InYieldSource0Before = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource1Before = hook.getAmountInYieldSource(currency1);

        (uint256 amount0, uint256 amount1) = hook.previewRedeem(shares);

        BalanceDelta removeDelta = hook.removeReHypothecatedLiquidity(shares, 0, 0);

        // withdrawn amount matches the previewed redeem, and is within a virtual-offset dust of the seeded amount
        assertEq(removeDelta.amount0().toUint256(), amount0, "Delta.amount0() != amount0");
        assertEq(removeDelta.amount1().toUint256(), amount1, "Delta.amount1() != amount1");
        assertApproxEqAbs(-addDelta.amount0(), removeDelta.amount0(), TOL);
        assertApproxEqAbs(-addDelta.amount1(), removeDelta.amount1(), TOL);

        uint256 lpAmount0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 lpAmount1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 amount0InYieldSource0After = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource1After = hook.getAmountInYieldSource(currency1);

        assertEq(lpAmount0After, lpAmount0Before + amount0, "lpAmount0After != lpAmount0Before + amount0");
        assertEq(lpAmount1After, lpAmount1Before + amount1, "lpAmount1After != lpAmount1Before + amount1");

        assertEq(
            amount0InYieldSource0After,
            amount0InYieldSource0Before - amount0,
            "amount0InYieldSource0After != amount0InYieldSource0Before - amount0"
        );
        assertEq(
            amount1InYieldSource1After,
            amount1InYieldSource1Before - amount1,
            "amount1InYieldSource1After != amount1InYieldSource1Before - amount1"
        );

        assertEq(hook.balanceOf(address(this)), 0, "Held shares != 0");
        assertEq(hook.totalSupply(), 0, "total shares != 0");
    }

    function test_remove_multipleLP() public {
        uint128 shareslp2 = 1e18;

        // lp1 seeds (holding SEED_SHARES), lp2 adds the same amount of shares.
        _seedBy(lp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2, type(uint256).max, type(uint256).max);

        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(SEED_SHARES, 0, 0);
        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2, 0, 0);

        // both held the same amount of shares, so remove approximately the same amount of assets
        assertApproxEqAbs(removeDeltalp1, removeDeltalp2, TOL);

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    function test_swap_remove_remove_multipleLP() public {
        uint128 shareslp2 = 1e18;

        _seedBy(lp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2, type(uint256).max, type(uint256).max);

        swap(key, true, 1e15, ZERO_BYTES);

        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(SEED_SHARES, 0, 0);
        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2, 0, 0);

        // both held the same amount of shares, so remove approximately the same amount of assets
        assertApproxEqAbs(removeDeltalp1, removeDeltalp2, TOL);

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    function test_remove_swap_remove_multipleLP() public {
        uint128 shareslp2 = 1e18;

        _seedBy(lp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2, type(uint256).max, type(uint256).max);

        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(SEED_SHARES, 0, 0);

        swap(key, true, 1e15, ZERO_BYTES);
        swap(key, false, 1e15 + 1e10, ZERO_BYTES);

        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2, 0, 0);

        // lp2 must have removed more assets, since the fees from the swap belong to it
        assertGt(removeDeltalp2.amount0(), removeDeltalp1.amount0());
        assertGt(removeDeltalp2.amount1(), removeDeltalp1.amount1());

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    function test_remove_yieldsGrowth_remove_multipleLP() public {
        uint128 shareslp2 = 1e18;

        _seedBy(lp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2, type(uint256).max, type(uint256).max);

        // lp1 removes
        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(SEED_SHARES, 0, 0);

        uint256 amount0InYieldSource = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource = hook.getAmountInYieldSource(currency1);

        // yield0 grows by 10%
        currency0.transfer(address(yieldSource0), amount0InYieldSource * 10 / 100);
        // yield1 grows by 20%
        currency1.transfer(address(yieldSource1), amount1InYieldSource * 20 / 100);

        // lp2 removes
        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2, 0, 0);

        // lp2 must have removed more assets, since the yield growth belongs to it
        assertApproxEqAbs(removeDeltalp2.amount0(), removeDeltalp1.amount0() * 110 / 100, TOL);
        assertApproxEqAbs(removeDeltalp2.amount1(), removeDeltalp1.amount1() * 120 / 100, TOL);

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    function test_remove_yieldsDecay_remove_multipleLP() public {
        uint128 shareslp2 = 1e18;

        _seedBy(lp1);
        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(shareslp2, type(uint256).max, type(uint256).max);

        // lp1 removes
        vm.prank(lp1);
        BalanceDelta removeDeltalp1 = hook.removeReHypothecatedLiquidity(SEED_SHARES, 0, 0);

        uint256 amount0InYieldSource = hook.getAmountInYieldSource(currency0);
        uint256 amount1InYieldSource = hook.getAmountInYieldSource(currency1);

        // yield0 decays by 10%
        hook.burnYieldSourcesBalance(currency0, amount0InYieldSource * 10 / 100);
        // yield1 decays by 20%
        hook.burnYieldSourcesBalance(currency1, amount1InYieldSource * 20 / 100);

        // lp2 removes
        vm.prank(lp2);
        BalanceDelta removeDeltalp2 = hook.removeReHypothecatedLiquidity(shareslp2, 0, 0);

        // lp2 must have removed less assets, since the yield decay belongs to it
        assertApproxEqAbs(removeDeltalp2.amount0(), removeDeltalp1.amount0() * 90 / 100, TOL);
        assertApproxEqAbs(removeDeltalp2.amount1(), removeDeltalp1.amount1() * 80 / 100, TOL);

        // both must have burned their shares
        assertEq(hook.balanceOf(lp1), 0);
        assertEq(hook.balanceOf(lp2), 0);

        // total supply should be 0
        assertEq(hook.totalSupply(), 0);
    }

    function test_remove_finalExit_leavesVirtualResidual() public {
        _seed();

        uint256 backing0 = hook.getAmountInYieldSource(currency0);
        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        hook.removeReHypothecatedLiquidity(hook.balanceOf(address(this)), 0, 0);

        uint256 received0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - before0;
        assertEq(hook.totalSupply(), 0, "all shares should be redeemed");
        assertGt(hook.getAmountInYieldSource(currency0), 0, "virtual shares keep a residual");
        assertEq(received0 + hook.getAmountInYieldSource(currency0), backing0, "residual is the unpaid remainder");
    }

    function test_remove_oneShareMint_doesNotBenefitAttacker() public {
        _seedBy(lp1);

        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        uint256 attacker0Before = token0.balanceOf(lp2);
        uint256 attacker1Before = token1.balanceOf(lp2);

        vm.prank(lp2);
        hook.addReHypothecatedLiquidity(1, type(uint256).max, type(uint256).max);

        uint256 lp1Before0 = token0.balanceOf(lp1);
        vm.prank(lp1);
        hook.removeReHypothecatedLiquidity(SEED_SHARES, 0, 0);
        uint256 lp1Received0 = token0.balanceOf(lp1) - lp1Before0;

        vm.prank(lp2);
        hook.removeReHypothecatedLiquidity(1, 0, 0);

        assertLe(token0.balanceOf(lp2), attacker0Before, "attacker profited in currency0");
        assertLe(token1.balanceOf(lp2), attacker1Before, "attacker profited in currency1");

        // the victim gets the same payout it would get without the attacker, up to the one-share dilution
        assertApproxEqAbs(lp1Received0, SEED * SEED / (SEED + 1e6), 1e6, "victim payout changed");
    }

    // -- DIFFERENTIAL -- //

    function testFuzz_differential_add_swap_remove_SingleLP(uint256 liquidity, int256 amountToSwap) public {
        liquidity = uint256(bound(liquidity, 1e12, 1e28)); // liquidity from 0.000001 to 10B
        amountToSwap = int256(bound(amountToSwap, 1e10, 1e26)); // swap from 0.00000001 to 100M tokens
        // assume the swap is less than half of the added liquidity
        vm.assume(amountToSwap * 2 < int256(liquidity));

        // amounts equivalent to `liquidity` at the current price, so the hook's JIT provision matches an
        // equivalent plain pool position.
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(hook.getTickLower()),
            TickMath.getSqrtPriceAtTick(hook.getTickUpper()),
            uint128(liquidity)
        );

        // -- Add liquidity --
        // Hooked
        (uint256 seedShares, BalanceDelta hookedAddDelta) = hook.seedLiquidity(amount0, amount1);
        // Unhooked, at the liquidity the hook provides, which rounding can leave an atom below `liquidity`
        uint256 hookedLiquidity = hook.getLiquidityToUse();
        BalanceDelta noHookAddDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), int256(hookedLiquidity), 0);
        assertApproxEqAbs(hookedAddDelta, noHookAddDelta, 1, "hookedAddDelta !~= noHookAddDelta");

        // -- Swap --
        // Unhooked
        BalanceDelta noHookSwapDelta = swap(noHookKey, true, amountToSwap, ZERO_BYTES);
        // Hooked
        BalanceDelta hookedSwapDelta = swap(key, true, amountToSwap, ZERO_BYTES);
        assertApproxEqAbs(hookedSwapDelta, noHookSwapDelta, 3, "hookedSwapDelta !~= noHookSwapDelta");

        // -- Remove liquidity --
        // Unhooked
        BalanceDelta noHookRemoveDelta =
            modifyPoolLiquidity(noHookKey, hook.getTickLower(), hook.getTickUpper(), -int256(hookedLiquidity), 0);
        // Hooked
        BalanceDelta hookedRemoveDelta = hook.removeReHypothecatedLiquidity(seedShares, 0, 0);
        assertApproxEqAbs(hookedRemoveDelta, noHookRemoveDelta, TOL, "hookedRemoveDelta !~= noHookRemoveDelta");
    }

    // -- JIT SIZING -- //

    function test_getLiquidityToUse_sizedByWithdrawableBalance() public {
        _seed();

        uint256 liqFull = hook.getLiquidityToUse();
        assertGt(liqFull, 0, "sanity: liquidity should be non-zero");

        // Cap currency0 withdrawals well below the seeded balance.
        uint256 cap = SEED / 1000;
        yieldSource0.setCap(cap);

        // The withdrawable amount now reflects the cap, and is below the reported balance...
        assertEq(hook.getMaxWithdrawFromYieldSource(currency0), cap, "max withdraw != cap");
        assertLt(cap, hook.getAmountInYieldSource(currency0), "cap should be below the reported balance");

        // ...so the just-in-time liquidity is sized down accordingly, never above what can be withdrawn back.
        assertLt(hook.getLiquidityToUse(), liqFull, "capped liquidity should be lower");
    }

    function test_swap_succeedsWhenBackingExceedsPerTickLimit() public {
        _seed();

        uint256 maxLiquidityPerTick = Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing);

        // Inflate both yield sources so the sizing would exceed the pool's per-tick gross-liquidity limit.
        deal(Currency.unwrap(currency0), address(yieldSource0), 3 * maxLiquidityPerTick);
        deal(Currency.unwrap(currency1), address(yieldSource1), 3 * maxLiquidityPerTick);

        assertGt(hook.getAmountInYieldSource(currency0), maxLiquidityPerTick, "backing should exceed the limit");
        assertLe(hook.getLiquidityToUse(), maxLiquidityPerTick, "JIT liquidity should be capped at the limit");

        uint256 balanceBefore = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        swap(key, true, -1e15, ZERO_BYTES);
        assertGt(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), balanceBefore, "swap should deliver output"
        );
    }

    /// @dev Deploys a hook with a fixed `[tickLower, tickUpper]` range on a pool initialized at `sqrtPriceX96`,
    /// seeded with `amount0` and `amount1`.
    function _deployFixedRange(int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        internal
        returns (FixedRangeReHypothecationMock h, PoolKey memory k)
    {
        CappedERC4626Mock ys0 = new CappedERC4626Mock(IERC20(Currency.unwrap(currency0)));
        CappedERC4626Mock ys1 = new CappedERC4626Mock(IERC20(Currency.unwrap(currency1)));
        address hookAddr = _flagAddr(0x70000000000000000000000000000000);
        deployCodeTo(
            "test/general/ReHypothecationHookERC4626.t.sol:FixedRangeReHypothecationMock",
            abi.encode(address(manager), address(ys0), address(ys1), tickLower, tickUpper),
            hookAddr
        );
        h = FixedRangeReHypothecationMock(payable(hookAddr));
        (k,) = initPool(currency0, currency1, IHooks(hookAddr), fee, sqrtPriceX96);
        IERC20(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
        h.seedLiquidity(amount0, amount1);
    }

    /// @dev Swaps until the price reaches `sqrtPriceLimitX96`.
    function _swapToPrice(PoolKey memory k, bool zeroForOne, uint160 sqrtPriceLimitX96) internal {
        swapRouter.swap(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e30, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_swap_succeedsAtLowerEdgeWithIdleCurrency1() public {
        (FixedRangeReHypothecationMock h, PoolKey memory k) =
            _deployFixedRange(-600, 600, SQRT_PRICE_1_1, SEED, 2 * SEED);

        // Park the price one unit inside the lower edge, where idle currency1 supports unbounded liquidity.
        _swapToPrice(k, true, TickMath.getSqrtPriceAtTick(-600) + 1);
        assertGt(h.getAmountInYieldSource(currency1), 0, "currency1 should remain idle");

        swap(k, false, -1e15, ZERO_BYTES);
        swap(k, true, -1e15, ZERO_BYTES);
    }

    function test_swap_succeedsAtUpperEdgeWithIdleCurrency0() public {
        (FixedRangeReHypothecationMock h, PoolKey memory k) =
            _deployFixedRange(-600, 600, SQRT_PRICE_1_1, 2 * SEED, SEED);

        // Park the price one unit inside the upper edge, where idle currency0 supports unbounded liquidity.
        _swapToPrice(k, false, TickMath.getSqrtPriceAtTick(600) - 1);
        assertGt(h.getAmountInYieldSource(currency0), 0, "currency0 should remain idle");

        swap(k, true, -1e15, ZERO_BYTES);
        swap(k, false, -1e15, ZERO_BYTES);
    }

    function test_swap_succeedsAtUpperEdgeAtHighPrice() public {
        // Near the maximum price, idle currency0 at the upper edge implies liquidity above `type(uint256).max`.
        (FixedRangeReHypothecationMock h, PoolKey memory k) =
            _deployFixedRange(886020, 887220, TickMath.getSqrtPriceAtTick(886620), SEED, SEED);

        _swapToPrice(k, false, TickMath.getSqrtPriceAtTick(887220) - 1);
        assertGt(h.getAmountInYieldSource(currency0), 0, "currency0 should remain idle");

        swap(k, true, -1e15, ZERO_BYTES);
    }

    function test_getLiquidityToUse_atLowerEdgeUsesCurrency0() public {
        (FixedRangeReHypothecationMock h, PoolKey memory k) = _deployFixedRange(-600, 600, SQRT_PRICE_1_1, SEED, SEED);
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(600);

        // At the lower edge the position holds only currency0, so only its backing sizes the liquidity.
        _swapToPrice(k, true, sqrtPriceLowerX96);
        assertEq(
            h.getLiquidityToUse(),
            LiquidityAmounts.getLiquidityForAmount0(
                sqrtPriceLowerX96, sqrtPriceUpperX96, h.getMaxWithdrawFromYieldSource(currency0)
            )
        );

        swap(k, false, -1e15, ZERO_BYTES);
    }

    function test_getLiquidityToUse_atUpperEdgeUsesCurrency1() public {
        (FixedRangeReHypothecationMock h, PoolKey memory k) = _deployFixedRange(-600, 600, SQRT_PRICE_1_1, SEED, SEED);
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(600);

        // At the upper edge the position holds only currency1, so only its backing sizes the liquidity.
        _swapToPrice(k, false, sqrtPriceUpperX96);
        assertEq(
            h.getLiquidityToUse(),
            LiquidityAmounts.getLiquidityForAmount1(
                sqrtPriceLowerX96, sqrtPriceUpperX96, h.getMaxWithdrawFromYieldSource(currency1)
            )
        );

        swap(k, true, -1e15, ZERO_BYTES);
    }

    function testFuzz_getLiquidityToUse_fitsBackingNearEdge(uint256 amount0, uint256 amount1, uint8 offsetBits) public {
        amount0 = bound(amount0, SEED, 1e27);
        amount1 = bound(amount1, SEED, 1e27);
        (FixedRangeReHypothecationMock h, PoolKey memory k) =
            _deployFixedRange(-600, 600, SQRT_PRICE_1_1, amount0, amount1);

        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(600);
        // Sample the distance to the edge on a log scale, so that the overflowing region near it is reached.
        _swapToPrice(k, true, sqrtPriceLowerX96 + uint160(1 << bound(offsetBits, 0, 90)));

        uint256 liquidity = h.getLiquidityToUse();
        assertLe(liquidity, Pool.tickSpacingToMaxLiquidityPerTick(k.tickSpacing), "liquidity above the per-tick limit");

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(k.toId());
        assertLe(
            SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpperX96, uint128(liquidity), true),
            h.getMaxWithdrawFromYieldSource(currency0) + 1,
            "currency0 required above backing"
        );
        assertLe(
            SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceX96, uint128(liquidity), true),
            h.getMaxWithdrawFromYieldSource(currency1) + 1,
            "currency1 required above backing"
        );
    }

    // -- SWAP REQUIRES USABLE JIT LIQUIDITY -- //

    function test_swap_revertsWhenJITLiquidityZero_cappedVault() public {
        _seed();

        // Gate currency1's yield source to zero withdrawable, leaving currency0 backed.
        yieldSource1.setCap(0);

        assertEq(hook.getMaxWithdrawFromYieldSource(currency1), 0, "currency1 withdrawable should be zero");
        assertGt(hook.getAmountInYieldSource(currency0), 0, "currency0 backing should remain");
        assertEq(hook.getLiquidityToUse(), 0, "JIT position should size to zero");

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ReHypothecationHook.NoUsableLiquidity.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e15, ZERO_BYTES);
    }

    function test_swap_revertsWhenJITLiquidityZero_vaultLoss() public {
        _seed();

        // Currency1's yield source loses its whole balance.
        hook.burnYieldSourcesBalance(currency1, hook.getAmountInYieldSource(currency1));

        assertEq(hook.getAmountInYieldSource(currency1), 0, "currency1 backing should be zero");
        assertGt(hook.getAmountInYieldSource(currency0), 0, "currency0 backing should remain");
        assertEq(hook.getLiquidityToUse(), 0, "JIT position should size to zero");

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ReHypothecationHook.NoUsableLiquidity.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, false, -1e15, ZERO_BYTES);
    }

    // -- ZERO-AMOUNT YIELD-SOURCE CALLS -- //

    function test_remove_zeroLeg_skipsZeroYieldSourceWithdraw() public {
        // currency0's yield source reverts on zero-amount withdrawals.
        RevertOnZeroERC4626Mock ys0r = new RevertOnZeroERC4626Mock(IERC20(Currency.unwrap(currency0)));
        CappedERC4626Mock ys1r = new CappedERC4626Mock(IERC20(Currency.unwrap(currency1)));
        address hookAddr = _flagAddr(0x30000000000000000000000000000000);
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(ys0r), address(ys1r)),
            hookAddr
        );
        ReHypothecationERC4626Mock h = ReHypothecationERC4626Mock(payable(hookAddr));
        initPool(currency0, currency1, IHooks(hookAddr), fee, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
        h.seedLiquidity(SEED, SEED);

        // Drain currency0's yield source so a proportional redeem prices its leg to zero (rounds down).
        h.burnYieldSourcesBalance(currency0, h.getAmountInYieldSource(currency0));

        uint256 smallShares = 1e6;
        (uint256 amount0, uint256 amount1) = h.previewRedeem(smallShares);
        assertEq(amount0, 0, "currency0 leg should redeem to zero");
        assertGt(amount1, 0, "currency1 leg should be non-zero");

        // Must not revert: the zero currency0 withdrawal is skipped instead of hitting the reverting yield source.
        h.removeReHypothecatedLiquidity(smallShares, 0, 0);
    }

    function test_remove_zeroLeg_rejectZeroTransferCurrency() public {
        // A pool where one currency reverts on zero-value transfers, as some tokens do.
        ERC20RejectZeroTransferMock rejectToken = new ERC20RejectZeroTransferMock();
        ERC20Mock plainToken = new ERC20Mock();
        bool rejectIsCurrency0 = address(rejectToken) < address(plainToken);
        (Currency c0, Currency c1) = rejectIsCurrency0
            ? (Currency.wrap(address(rejectToken)), Currency.wrap(address(plainToken)))
            : (Currency.wrap(address(plainToken)), Currency.wrap(address(rejectToken)));

        ERC4626YieldSourceMock ys0 = new ERC4626YieldSourceMock(IERC20(Currency.unwrap(c0)));
        ERC4626YieldSourceMock ys1 = new ERC4626YieldSourceMock(IERC20(Currency.unwrap(c1)));
        address hookAddr = _flagAddr(0x40000000000000000000000000000000);
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(ys0), address(ys1)),
            hookAddr
        );
        ReHypothecationERC4626Mock h = ReHypothecationERC4626Mock(payable(hookAddr));
        initPool(c0, c1, IHooks(hookAddr), fee, SQRT_PRICE_1_1);

        ERC20Mock(Currency.unwrap(c0)).mint(address(this), 1e24);
        ERC20Mock(Currency.unwrap(c1)).mint(address(this), 1e24);
        IERC20(Currency.unwrap(c0)).approve(hookAddr, type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(hookAddr, type(uint256).max);
        h.seedLiquidity(SEED, SEED);

        // Drain the reject-zero currency's yield source of its underlying, so its leg redeems to zero.
        Currency rejectCurrency = rejectIsCurrency0 ? c0 : c1;
        Currency fundedCurrency = rejectIsCurrency0 ? c1 : c0;
        address rejectYs = rejectIsCurrency0 ? address(ys0) : address(ys1);
        uint256 held = IERC20(Currency.unwrap(rejectCurrency)).balanceOf(rejectYs);
        vm.prank(rejectYs);
        IERC20(Currency.unwrap(rejectCurrency)).transfer(address(0xdead), held);

        (uint256 amount0, uint256 amount1) = h.previewRedeem(1e6);
        assertEq(rejectIsCurrency0 ? amount0 : amount1, 0, "reject-zero leg should redeem to zero");
        assertGt(rejectIsCurrency0 ? amount1 : amount0, 0, "the funded leg should be non-zero");

        uint256 balanceBefore = IERC20(Currency.unwrap(fundedCurrency)).balanceOf(address(this));
        h.removeReHypothecatedLiquidity(1e6, 0, 0);
        assertGt(
            IERC20(Currency.unwrap(fundedCurrency)).balanceOf(address(this)),
            balanceBefore,
            "the funded leg should be received"
        );
    }

    // -- JIT TICK SNAPSHOT -- //

    function test_swap_dynamicTicks_snapshotsRangeAcrossSwap() public {
        CappedERC4626Mock ys0d = new CappedERC4626Mock(IERC20(Currency.unwrap(currency0)));
        CappedERC4626Mock ys1d = new CappedERC4626Mock(IERC20(Currency.unwrap(currency1)));
        address hookAddr = _flagAddr(0x40000000000000000000000000000000);
        deployCodeTo(
            "test/general/ReHypothecationHookERC4626.t.sol:DynamicTickReHypothecationMock",
            abi.encode(address(manager), address(ys0d), address(ys1d)),
            hookAddr
        );
        DynamicTickReHypothecationMock h = DynamicTickReHypothecationMock(payable(hookAddr));
        (PoolKey memory dynKey,) = initPool(currency0, currency1, IHooks(hookAddr), fee, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
        h.seedLiquidity(SEED, SEED);

        (, int24 tickBefore,,) = StateLibrary.getSlot0(manager, dynKey.toId());

        // A large exact-input swap moves the tick, so the dynamic range would shift between beforeSwap and
        // afterSwap. With the range snapshotted, afterSwap removes exactly what beforeSwap added and the swap
        // succeeds; without it the position would be orphaned and the swap would revert.
        swap(dynKey, true, -5e17, ZERO_BYTES);

        (, int24 tickAfter,,) = StateLibrary.getSlot0(manager, dynKey.toId());
        assertTrue(tickBefore != tickAfter, "swap should move the tick, exercising the range shift");
    }

    // -- SETTLEMENT REENTRANCY -- //

    function test_afterSwap_liquidityReentrancy_blocked() public {
        // currency1's yield source reenters removeReHypothecatedLiquidity during afterSwap's withdrawal.
        CappedERC4626Mock ys0m = new CappedERC4626Mock(IERC20(Currency.unwrap(currency0)));
        ReentrantYieldSourceMock ys1m = new ReentrantYieldSourceMock(IERC20(Currency.unwrap(currency1)));
        address hookAddr = _flagAddr(0x50000000000000000000000000000000);
        deployCodeTo(
            "src/mocks/general/ReHypothecationERC4626Mock.sol:ReHypothecationERC4626Mock",
            abi.encode(address(manager), address(ys0m), address(ys1m)),
            hookAddr
        );
        ReHypothecationERC4626Mock h = ReHypothecationERC4626Mock(payable(hookAddr));
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(hookAddr), fee, SQRT_PRICE_1_1);

        IERC20(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
        h.seedLiquidity(SEED, SEED);

        ys1m.arm(h);

        // zeroForOne swap → hook owes currency1 → withdraw(currency1) in afterSwap → reentrancy attempt.
        swap(k, true, -1e15, ZERO_BYTES);

        assertTrue(ys1m.reentered(), "reentrancy should have been attempted");
        assertEq(
            ys1m.reentryRevertReason(),
            abi.encodeWithSelector(ReHypothecationHook.JITLocked.selector),
            "reentrant liquidity op should be blocked by the JIT lock"
        );
    }

    // -- POOL KEY VALIDATION -- //

    function test_beforeInitialize_override_gatesBinding() public {
        CappedERC4626Mock ys0v = new CappedERC4626Mock(IERC20(Currency.unwrap(currency0)));
        CappedERC4626Mock ys1v = new CappedERC4626Mock(IERC20(Currency.unwrap(currency1)));
        address hookAddr = _flagAddr(0x60000000000000000000000000000000);
        deployCodeTo(
            "test/general/ReHypothecationHookERC4626.t.sol:ValidatingReHypothecationMock",
            abi.encode(address(manager), address(ys0v), address(ys1v)),
            hookAddr
        );

        // A pool with the wrong fee (1000) is rejected by the override, so the hook stays unbound.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hookAddr,
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(ValidatingReHypothecationMock.WrongPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        initPool(currency0, currency1, IHooks(hookAddr), 1000, SQRT_PRICE_1_1);

        // The expected fee (3000) is accepted and binds the hook.
        initPool(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        assertEq(ValidatingReHypothecationMock(payable(hookAddr)).getPoolKey().fee, 3000);
    }
}
