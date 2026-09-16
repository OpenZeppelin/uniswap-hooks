# Invariant Spec: AntiSandwichHook

- **Target:** `src/general/AntiSandwichHook.sol`
- **Campaign:** `AntiSandwichHookInvariants.t.sol`
- **Prefix:** `INV`

The hook records the pool price at the first swap of each block. Every later swap in that block is held to
that price: valued at it, a swap may never receive more than it paid. The difference is taken as a hook fee.

"The bound" throughout is that limit, which the hook returns to {BaseDynamicAfterFee} as
`targetUnspecifiedAmount`.

The bound is arithmetic over two amounts the swap's own `BalanceDelta` already carries. It reads no tick
data, no liquidity and no tick spacing, so there is no beginning-of-block state it has to reconstruct and
therefore no state it can fail to reconstruct. It prices every swap, with one edge that is a choice rather
than a failure: where the bound passes what a `BalanceDelta` carries, a ceiling is dropped because it cannot
bind, and a floor past it is refused rather than dropped. See INV-05.

The pool runs with a zero LP fee, so a sandwich that loses money in this campaign lost it to the mechanism
rather than to the pool's spread. The campaign drives the shipped example, `AntiSandwichMock`,
rather than a handler written for it, so what is fuzzed is what ships.

## Rounding

Every rounding in the bound favors the swapper. That is the direction that matters: a swap which did not
beat the beginning-of-block price is never charged, which INV-04 asserts exactly.

The cost is that the bound is loose by the resolution of converting between the two currencies twice. The
campaign expresses that as `_boundSlack`, derived from the price rather than chosen, and allows a sandwich
to come out ahead by at most two of them, one for each bounded leg.

The hook converts one way and the assertion converts back, and a round trip loses more than either leg. Each
`mulDiv` loses under a unit, the first loss of each leg is carried across by that leg's ratio, and the two
ratios are the square root of the price and the price itself. So the slack is `sqrt(price) + price + 2`,
in the units the comparison is made in.

That grows with the price and never with the size of a swap: single-digit wei at a checkpoint of 1, and
482,263,073 at a checkpoint near tick 399,900 against a bound of 2.3e29 there. Deriving it rather than
fixing a constant is what makes the invariant hold at both ends, and what keeps it from being so loose at
high prices that it stops saying anything.

## INV-01: A swap is never filled better than the beginning-of-block price

- Buying currency0: `paid1 + slack >= received0 * price`
- Selling currency0: `received1 <= paid0 * price + slack`
- Holds. 80 runs, 40k calls. 335 checks per sequence at the default depth.
- Asserted in the handler as every swap returns, so it covers the whole swap surface rather than a sample.
- `price` is read back from the hook's own checkpoint getter, and the comparison is two `mulDiv` calls that
  the hook does not participate in.

## INV-02: The checkpoint changes only when a new block claims it

- `checkpoint_after != checkpoint_before ⟹ ( blockNumber_after == block.number ∧ blockNumber_before !=
  block.number )`
- Holds. 80 runs, 40k calls.
- Transition property, asserted around every action including the ones that take no swap. Both halves
  matter: the first rejects a checkpoint written without claiming the block, the second rejects one
  rewritten inside the block that already owned it.

## INV-03: No sandwich ends a block ahead

- For a front run, a victim and a back run in one block, closing the size the attack opened:
  `value_after - value_before <= 2 * slack`, valued in currency1 at the price the block is measured against
- Holds. 80 runs, 40k calls. 53 plain and 45 JIT sandwiches measured end to end per sequence.
- Both directions are exercised: opening with a buy and opening with a sell.
- **The JIT arm is a matched pair.** An attacker who also supplies the liquidity the victim trades through
  earns whatever a liquidity provider earns, which no bound on swaps can reach. The handler therefore runs
  the identical plan twice under state snapshots: once with the attacker taking both swap legs, once with an
  unrelated actor taking the identical legs while the attacker only provides. The invariant is over the
  difference, which is what swapping bought the attacker.
- Without the matched control this reads as a large profit. It is not the bound failing. Two effects
  account for it, and both were separated by measurement rather than argued away: a provider whose position
  is in range while the price moves is valued differently at the block's opening price, and a handler that
  donates the fee to in-range liquidity hands it back to whoever holds that liquidity. Switching the
  campaign's handler from donating to retaining removed 99.98% of the apparent profit.

## INV-04: The first swap of a block pays no fee

- For the first swap of a block: `fee == 0`
- Holds. 80 runs, 40k calls. 58 first swaps per sequence.
- Not a restatement. The fee comes from the `HookFee` log and "first" is decided from the checkpoint's own
  block number, so neither side of the claim comes from the bound.
- The checkpoint is the price standing before the swap ran, and a swap moves the price away from it, so
  there is never an improvement to take. This is the invariant that caught the rounding running the wrong
  way: an exactly-at-price fill was charged one wei.

## INV-05: The hook never rejects a swap the pool accepted

- No swap reverts through the hook
- Holds. 80 runs, 40k calls.
- A revert is attributed to the hook only when the pool manager wraps it in `CustomRevert.WrappedError`
  naming the hook, so a pool-level rejection such as `PriceLimitAlreadyExceeded` is never counted against
  it.
- This is what a reconstructed bound could not provide. A bound that has to rebuild the beginning-of-block
  pool has states it cannot rebuild, and every one of them is either a swap it must refuse or a swap it must
  let past uncapped.
- It also caught the fee handler donating into a pool the swap had left with no active liquidity, which
  `Pool.donate` rejects.
- **Two deliberate exceptions, both outside the range this campaign runs in.** `TargetOutOfRange` refuses a
  swap whose floor passes what a `BalanceDelta` carries, and `CheckpointNotSet` refuses one against a pool
  holding no price, which `beforeSwap` makes unreachable. The campaign runs at a price of 1, where neither is
  reachable; `testFuzz_theBoundHoldsAcrossPricesAndSpacings` reaches the first by fuzzing ticks to ±350,000,
  and `test_theBoundDoesNotSwitchOffOnALargeLeg` pins both sides of its crossing. Charging nothing there is
  what an adversarial pass found and is strictly worse: it lets a swapper turn the target off by choosing the
  size, which is the failure this whole design exists to remove.

  The one place the hook still charges nothing is an exact input whose **ceiling** overflows, and that is not
  an exception at all. Such a ceiling is above every amount the swap could have received, so the fee it would
  produce is zero either way. Refusing there would reject ordinary swaps for no gain: at a recorded price of
  `1e-20`, spending about 1.7 tokens of currency1 already puts the ceiling past the range.

## INV-06: The checkpoint never claims a block that has not happened

- `checkpoint.blockNumber <= block.number`
- Holds. 80 runs, 40k calls.
- Carries no detection power of its own: `stateTransition` already asserts the stronger
  `blockAfter == block.number` around every action. Kept because it states the property standalone, not
  because a mutation reaches it that INV-02 does not.

## INV-07: A checkpoint that claims the current block holds a price

- `checkpoint.blockNumber == block.number ⟹ checkpoint.sqrtPriceX96 != 0`
- Holds. 80 runs, 40k calls.
- Separates a written checkpoint from the zero slot a missing one leaves. The hook takes no fee against a
  zero price, so this is what makes the bound apply rather than abstain.

## INV-08: Every fee reaches the recipient, and none rests in the hook

- `claims_c(recipient) == sum of fees taken in c` and `claims_c(hook) == 0`, for both currencies
- Holds. 80 runs, 40k calls.
- The totals come from the `HookFee` log rather than from the handler, so the claim does not rest on the
  hook's own accounting. Together with INV-03 this is what says the fee leaves the attacker's reach: it is
  accounted for, and it is not in a place the attacker can arrange to hold.

## INV-09: A swap costs the same whatever the price did since the last block

- `max(gas of a first swap of a block) < 1_000_000`
- Holds. 80 runs, 40k calls. 403,941 measured.
- The checkpoint is one slot and nothing the hook reads scales with the distance the price travelled.

## Not invariants, enforced by the campaign

`fail_on_revert = true`, so any revert the handler's own actions cause fails the sequence.

## Closed outside the campaign

Four adversarial rounds, now in `AntiSandwichHook.t.sol` as `AntiSandwichHookAdversarialTest`, closed these
by measurement rather than argument.

- **The checkpoint cannot be moved by reentering the hook.** A fee handler that swaps back into the same
  pool while `afterSwap` is on the stack reads the same checkpoint before, during and after. There is no
  external call between the two writes in `_beforeSwap`, and the bound reads the struct in one load, so there
  is no half-written window. A reentrant token is strictly weaker, since its callback fires during settle,
  after the swap has finished.
- **One hook over several pools does not mix them.** Three pools opened at three different prices, six
  interleaved swaps in one block, every checkpoint still its own pool's opening price.
- **A fee collected with no active liquidity survives.** A swap through the whole book still collects and
  forwards 68,330,791,733,993,641. The same swap against a donating handler reverts from inside `afterSwap`,
  which is the class the recipient design removes outright.
- **No ERC-20 is called on the fee path.** The fee is collected with `poolManager.mint` and forwarded with
  an ERC-6909 `transfer`, so a token that charges a transfer fee, rebases, or rejects a recipient has no
  reachable call site in the hook or its example. This is closed by construction rather than by a test, which
  is why no hostile-token case appears above.
- **A swap stopped early by its own price limit is bound on what it filled**, at three limits, with currency0
  received equal to currency1 spent in each. A partial fill is not a way past the bound.

The live hazard the rounds did not close is `_getBlockNumber`. A clock that moves inside a block makes every
swap its own checkpoint and the attacker's result equals the unprotected one to the wei
(+47,619,047,619,047,618 against −33,333,333,333,333,334 with the shipped clock); a frozen clock anchors the
pool for good. Both are silent, which is why the function carries an `IMPORTANT` rather than a `NOTE`.

## Properties the implementation does not provide

Stated so the absence is deliberate rather than an oversight.

- **The bound is the pool at the start of the block.** It is the *price* at the start of the block, which the
  read at the block's first swap records exactly, since only a swap moves `slot0.sqrtPriceX96`. It is not the
  pool: depth added or removed earlier in the block is not part of the baseline, because no depth is.
- **Liquidity provision is bounded.** It is not. The hook bounds swaps, so an attacker can supply the
  liquidity a victim trades through and withdraw it in the same block. INV-03 measures this arm separately
  rather than claiming it away. `LiquidityPenaltyHook` addresses it.
- **The fee is out of the attacker's reach.** That is the fee handler's choice, not the hook's, and paying
  in-range liquidity never satisfies it. `test_A_theFeeDestinationDecidesWhetherTheAttackerKeepsIt` measures
  both ways of trying:
  donating inside the block leaves +10,048,105,725,641,797 against +10,792,292,147,772,763 unprotected, and
  deferring a block leaves +2,349,023,506,258,137 against +2,394,170,154,084,658 once the attacker holds the
  position rather than withdrawing it. The shipped example pays a recipient fixed at deployment, which is
  the only one of the three an attacker cannot arrange to be, and INV-08 fuzzes it.
- **A sandwich is bounded across blocks.** The baseline resets each block, so an attack whose opening and
  closing legs sit in different blocks is measured against a price its own opening leg set. Measured at
  36,946,530,014,970,521, identical to the pool with no hook at all, so it belongs to the per-block baseline
  rather than to the bound. The umbra design names it.
- **A block's price cannot be moved to everyone else's cost.** Whoever takes a block's first swap sets the
  price every later swap in it is held to, so moving it makes the rest of the block expensive. After an 8e17
  crash an honest 1e16 buy costs 10,000,000,000,000,000 against 5,529,243,251,788,365 with no hook. It costs
  the mover 344,309,317,943,696,789, since it is held to the same price squaring its own position, and what a
  swapper loses is capped at the opening price rather than growing with the crash.
- **The cost falls only on the direction a sandwich closes in.** The bound holds both, which is what closes
  the mirrored sandwich, so a seller pays it too. After the block's first swap pumped the price, a seller of
  1e16 receives 10,000,000,000,000,000 against 17,977,967,870,073,389 with no hook.
- **A swap is never filled worse than the target.** The mechanism only takes the improvement, so liquidity
  pulled after the checkpoint gives a victim a worse fill and no compensation.

## Fuzzable surface

`swap`, `sandwich`, `jitSandwich`, `addLiquidity`, `removeLiquidity`, `donate`, `nextBlock`.

`sandwich` runs a front run, a victim and a back run in one block, because the fuzzer rarely composes three
legs into the same block and the checkpoint only matters across one. `jitSandwich` does the same with the
attacker supplying the liquidity, and measures the matched pair described under INV-03.

## Coverage the campaign asserts

Per sequence, `afterInvariant` requires that every action ran, that some block saw more than one swap, that
some swap paid a fee, that INV-01 was asserted, and that sandwiches were measured end to end. Without the
fee count the bound invariants are vacuous.
