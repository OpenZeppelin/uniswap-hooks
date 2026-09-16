# Invariant Spec: AntiSandwichHook

- **Target:** `src/general/AntiSandwichHook.sol`
- **Campaign:** `AntiSandwichHookInvariants.t.sol`
- **Prefix:** `INV`

The hook records the pool price at each block's first swap and holds every later swap in that block to it:
valued at that price, a swap may not receive more than it paid, and the difference is taken as a hook fee.
"The bound" below is that limit, returned to {BaseDynamicAfterFee} as `targetUnspecifiedAmount`.

Every rounding favors the swapper, so the bound is loose by `sqrt(price) + price + 2` in the units compared.
`_boundSlack` derives that rather than fixing a constant, and INV-01 and INV-03 carry it.

All of the below hold at 80 runs by 500 depth, against the shipped `AntiSandwichMock`, on a pool with a zero
LP fee so that a sandwich which loses money lost it to the mechanism rather than to the spread.

## INV-01: A swap is never filled better than the beginning-of-block price

- Buying currency0: `paid1 + slack >= received0 * price`; selling: `received1 <= paid0 * price + slack`
- Asserted as every swap returns, so it covers the swap surface rather than a sample. 335 checks per
  sequence.
- `price` is read back from the hook's own getter, and the comparison is two `mulDiv` calls the hook does not
  participate in.

## INV-02: The checkpoint changes only when a new block claims it

- `checkpoint_after != checkpoint_before` implies `blockNumber_after == block.number` and
  `blockNumber_before != block.number`
- Asserted around every action, including those that take no swap. Both halves matter: the first rejects a
  checkpoint written without claiming the block, the second one rewritten inside the block that owned it.

## INV-03: No sandwich ends a block ahead

- For a front run, a victim and a back run in one block closing the size it opened:
  `value_after - value_before <= 2 * slack`, valued in currency1 at the block's own price
- Both directions, opening with a buy and with a sell. 53 plain and 45 own-book sandwiches per sequence.
- **The own-book arm is a matched pair, and is not a test of liquidity provision.** It asks whether owning
  the book the swaps run through gives them any leverage over the bound. The handler runs the identical plan
  twice under state snapshots, once with the attacker taking both legs and once with an unrelated actor
  taking them, and the invariant is over the difference, so what a provider earns cancels. Without that
  control the arm reads as a large profit that is not the bound failing.

## INV-04: The first swap of a block pays no fee

- `fee == 0` for the first swap of a block. 58 per sequence.
- Not a restatement: the fee comes from the `HookFee` log and "first" is decided from the checkpoint's block
  number, so neither side of the claim comes from the bound.

## INV-05: The hook never rejects a swap the pool accepted

- A revert counts only when the pool manager wraps it in `CustomRevert.WrappedError` naming the hook, so a
  pool-level rejection such as `PriceLimitAlreadyExceeded` is never charged to it.
- This is what a reconstructed bound could not provide: every state it failed to rebuild was a swap it had to
  refuse or let past uncapped.
- **Two deliberate exceptions, both outside the range the campaign runs in.** `TargetOutOfRange` refuses a
  swap whose floor passes what a `BalanceDelta` carries; `CheckpointNotSet` refuses one against a pool
  holding no price, which `_beforeSwap` makes unreachable. `testFuzz_theBoundHoldsAcrossPricesAndSpacings`
  reaches the first by fuzzing ticks to plus or minus 350,000, and `test_theBoundDoesNotSwitchOffOnALargeLeg`
  pins both sides of its crossing. Charging nothing instead would let a swapper turn the bound off by
  choosing the size.
- An exact input whose **ceiling** overflows is charged nothing, and that is not a third exception: such a
  ceiling is above every amount the swap could have received, so the fee is zero either way. Refusing there
  would reject ordinary swaps, since at a price of `1e-20` about 1.7 tokens already puts the ceiling past the
  range.

## INV-06: The checkpoint never claims a block that has not happened

- `checkpoint.blockNumber <= block.number`
- No detection power of its own, since INV-02 asserts the stronger equality. Kept as a standalone statement.

## INV-07: A checkpoint that claims the current block holds a price

- `checkpoint.blockNumber == block.number` implies `checkpoint.sqrtPriceX96 != 0`
- Separates a written checkpoint from the zero slot a missing one leaves.

## INV-08: Every fee reaches the recipient, and none rests in the hook

- `claims_c(recipient) == sum of fees taken in c` and `claims_c(hook) == 0`, both currencies
- Totals come from the `HookFee` log rather than the handler, so the claim does not rest on the hook's own
  accounting. With INV-03 this is what puts the fee beyond the attacker's reach.

## INV-09: A swap costs the same whatever the price did since the last block

- `max(gas of a first swap of a block) < 1_000_000`. 403,941 measured.
- The checkpoint is one slot and nothing the hook reads scales with the distance travelled.

## Enforced by the campaign rather than asserted

`fail_on_revert = true`, so any revert the handler's own actions cause fails the sequence.

## Closed outside the campaign

By `AntiSandwichHookAdversarialTest`, over four adversarial rounds.

- **Reentering the hook cannot move the checkpoint.** A fee handler that swaps back into the same pool while
  `afterSwap` is on the stack reads the same checkpoint throughout. There is no external call between the two
  writes in `_beforeSwap`, so there is no half-written window; a reentrant token is weaker still, since its
  callback fires after the swap has finished.
- **One hook over several pools does not mix them.** Three pools at three prices, six interleaved swaps in
  one block, every checkpoint still its own.
- **A fee collected with no active liquidity survives**, where a donating handler reverts from inside
  `afterSwap`.
- **No ERC-20 is called on the fee path.** Collected with `poolManager.mint`, forwarded as an ERC-6909
  transfer, so transfer-fee, rebasing and blocklisting tokens have no reachable call site. Closed by
  construction, which is why no hostile-token case appears above.
- **A swap stopped early by its own price limit is bound on what it filled.** A partial fill is not a way
  past the bound.

The hazard the rounds did not close is `_getBlockNumber`. A clock that moves inside a block makes every swap
its own checkpoint, and the attacker's result equals the unprotected one to the wei; a frozen clock anchors
the pool for good. Both are silent, which is why the function carries an `IMPORTANT`.

## Properties the implementation does not provide

Stated so each absence is deliberate rather than an oversight.

- **The bound is the pool at the start of the block.** It is the *price* at the start of the block, recorded
  exactly, since only a swap moves `slot0.sqrtPriceX96`. It is not the pool: no depth enters the baseline.
- **Liquidity provision is bounded.** It is not. An attacker can supply the liquidity a victim trades through
  and withdraw it in the same block. INV-03 measures that arm separately; `LiquidityPenaltyHook` addresses
  it.
- **The fee is out of the attacker's reach.** That is the handler's choice, and paying in-range liquidity
  never satisfies it. Donating inside the block leaves 10,048,105,725,641,797 against 10,792,292,147,772,763
  unprotected, and deferring a block leaves 2,349,023,506,258,137 against 2,394,170,154,084,658 once the
  attacker holds the position. The shipped example pays a fixed recipient, the only one of the three an
  attacker cannot arrange to be.
- **A sandwich is bounded across blocks.** The baseline resets each block, so an attack spanning two is
  measured against a price its own opening leg set. Measured at 36,946,530,014,970,521, identical to no hook
  at all. The umbra design names it.
- **A block's price cannot be moved to everyone else's cost.** Whoever takes the first swap sets the price
  the rest of the block is held to. After an 8e17 crash an honest 1e16 buy costs 10,000,000,000,000,000
  against 5,529,243,251,788,365 unprotected. It costs the mover 344,309,317,943,696,789, and a swapper's loss
  is capped at the opening price rather than growing with the crash.
- **The cost falls only on the direction a sandwich closes in.** The bound holds both, which is what closes
  the mirrored sandwich, so a seller pays it too: after a pump, a seller of 1e16 receives
  10,000,000,000,000,000 against 17,977,967,870,073,389 unprotected.
- **A swap is never filled worse than the bound.** Only the improvement is taken, so liquidity pulled after
  the checkpoint gives a victim a worse fill and no compensation.

## Fuzzable surface and coverage

`swap`, `sandwich`, `sandwichOverOwnBook`, `addLiquidity`, `removeLiquidity`, `donate`, `nextBlock`.

`sandwich` composes three legs into one block, which the fuzzer rarely does by itself and which is the only
arrangement the checkpoint matters across. `sandwichOverOwnBook` adds the attacker supplying the liquidity.

`afterInvariant` requires per sequence that every action ran, that a block saw more than one swap, that a
swap paid a fee, that INV-01 was asserted and that sandwiches were measured end to end. Without the fee count
the bound invariants are vacuous.
