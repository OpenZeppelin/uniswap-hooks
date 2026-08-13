# Invariant Spec: LimitOrderHook lifecycle

- **Target contract:** `src/general/LimitOrderHook.sol` (via `src/mocks/general/LimitOrderHookMock.sol`)
- **Campaign:** `LimitOrderHookInvariants.t.sol`
- **Status:** the `F`, `S` and `C` blocks hold. The `P` and `A` blocks are pending.

> **Terminology**
>
> The contract has no `cancelled` flag. An order carries one boolean, `filled`, written only by
> `_fillOrder`. An order id is:
>
> - **active** when `getOrderId(key, tickLower, zeroForOne)` returns it. Implies `filled == false`.
> - **filled** when `filled == true`. `_fillOrder` retires the key in the same call, so a filled order
>   is never active.
> - **cancelled** when the key that once resolved to it now returns `ORDER_ID_DEFAULT` while `filled`
>   is false. Only a cancel of the last remaining liquidity produces this, so "cancelled" and "fully
>   cancelled" are the same state. A partial cancel leaves the order active.
>
> A retired id is never reachable through the key mapping again, so every invariant below quantifies
> over a handler-maintained set of ids rather than over live state.

> **Prefixes**
>
> `F` covers the fill lifecycle and per-order accounting, `P` placement and fee entitlement, `C`
> cancellation, `S` system-level solvency, `A` access control. Each entry names the state it is scoped
> to.

> **Fee accounting**
>
> Fees are tracked as `accFee_cPerLiqX128`, the fees credited to an order per unit of liquidity. It
> only ever increases. Each owner holds `feeCheckpoint_cX128`, the value the accumulator is read
> against for them, and is owed `mulDiv(acc_c - ckpt_c, liq, Q128)`. Principal is tracked separately
> as `principalCredited_c`, credited once by the fill and split pro-rata.

## F: fill lifecycle and order accounting

### INV-F-01: An order's total liquidity equals the sum of its owners' liquidity

- **scope:** all orders
- **statement:** `liquidityTotal` equals the sum of the per-owner `liquidity` entries.
- **predicate:** `∀o: liqTotal(o) == Σ_{a ∈ actors} liq(o, a)`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- **assumption:** the actor set is complete, which holds because the handler pranks every `placeOrder`
  as one of its own actors.

### INV-F-02: A fully withdrawn order holds no liquidity

- **scope:** orders every owner has withdrawn from
- **statement:** Once every owner of an order has withdrawn, the order records no liquidity.
- **predicate:** `∀o: fullyWithdrawn(o) ⟹ liqTotal(o) == 0`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- **why it is a claim and not a restatement:** `fullyWithdrawn` is the handler's owner count and reads
  neither `liquidityTotal` nor `principalCredited`. Deriving the flag from `liquidityTotal == 0`, as an
  earlier version did, made this and INV-F-03 tautologies.

### INV-F-03: A fully withdrawn order has no remaining principal

- **scope:** orders every owner has withdrawn from, per currency
- **statement:** Once every owner of an order has withdrawn, the principal the order records is zero.
- **predicate:** `∀o: fullyWithdrawn(o) ⟹ principalCredited_c(o) == 0`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- **exactness:** no dust term. Each withdrawal takes `mulDiv(P, l, L)` and the denominator shrinks
  alongside the numerator, so the last owner out has `l == L`, gets `mulDiv(P, L, L) == P`, and carries
  off every earlier remainder.
- **what it does not cover:** the fee residual. The last withdrawal deletes every `userInfo`, so
  `Σ_a owed_c` is trivially zero and the order stores no fee pot to compare against. INV-S-01's surplus
  bound is the only place that residual is observable.

### INV-F-04: An order is filled as soon as the price crosses its tick

- **scope:** active orders
- **statement:** No active order remains on the side of the price its range has already been crossed
  by. A `zeroForOne` order at `t` must not survive the current tick lower moving above `t`, and the
  reverse for a `!zeroForOne` order.
- **predicate:** `∀ active (t, d): d ? tickLowerNow <= t : tickLowerNow >= t`, where
  `tickLowerNow = _getTickLower(currentTick, tickSpacing)`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- **threshold derivation:** a price-rising swap fills `zeroForOne` orders at ticks in
  `[tickLowerLast, L - spacing]`, so a survivor must satisfy `L <= t`, symmetrically for the other
  direction. Computed from the pool's own price and never from `getTickLowerLast`, so a drifted tracker
  cannot make this agree with itself.

### INV-F-05: A filled order cannot be cancelled

- **scope:** filled orders
- **statement:** For any order with `filled == true`, `cancelOrder` reverts for every caller.
- **predicate as tested:** `∀ active (t, d): ¬filled(orderId(t, d))`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- **why this predicate:** `cancelOrder` resolves the order id from `(key, tickLower, zeroForOne)`. Once
  `_fillOrder` retires the key the call lands on `_orderInfos[0]`, which no order is ever allocated to.
  A filled order is unaddressable rather than guarded, and the revert is `ZeroLiquidity`.

### INV-F-06: The recorded tick lower tracks the pool price

- **scope:** all states
- **statement:** The tick lower the hook has stored for a pool equals the tick lower of that pool's
  current price.
- **predicate:** `getTickLowerLast(poolId) == _getTickLower(currentTick, tickSpacing)`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.

## P: placement and fee entitlement

Both entries below are **transition properties**, over the state before and after a single
`placeOrder`, not predicates over state at rest. A Foundry `invariant_` function cannot express them,
so they are asserted inside the handler's `placeOrder` around the call, the same way the liveness
claims are covered by attempting the call.

Neither reads a view for the amount owed, because the hook exposes none. Both recompute it as
`owed_c(o, a) = mulDiv(acc_c(o) - ckpt_c(o, a), liq(o, a), Q128)`.

Together they bracket H-01 from both sides. The bug was an absolute checkpoint, which entitled a
placer to fees the order accrued before their liquidity existed. Writing the checkpoint to `acc`
instead is the opposite defect, forfeiting what the placer was already owed. INV-P-01 rules out the
first, INV-P-02 the second, and the discount `ckpt_new = acc - owed/liqNew` is the only value that
satisfies both.

### INV-P-01: A first placement inherits no fees

- **scope:** each `placeOrder` whose caller held no liquidity in the order beforehand
- **statement:** Immediately after an actor's first placement into an order, the order owes them
  nothing.
- **predicate:** `owed_c(o, X) == 0` after `placeOrder`, given `liq(o, X) == 0` before
- **status:** not implemented.
- **why it is exactly H-01:** entitlement begins at the placement, so any nonzero value here is a
  transfer out of the existing owners' fees and into the new placer's.
- **exactness:** no tolerance. A fresh owner has `liq == 0`, so `_feesOwed` returns zero and the
  checkpoint is written at `acc` itself, which makes the difference identically zero rather than merely
  small.
- **coverage note:** the assertion is reached on every placement, but it is only *informative* on an
  order that already accrued fees. A first placement into an empty order passes trivially, since the
  accumulator is still zero.

### INV-P-02: A placement does not reduce another owner's fees

- **scope:** each `placeOrder`, over every actor holding liquidity in the order beforehand
- **statement:** No pre-existing owner is owed less after a placement than before it.
- **predicate:** `∀a ≠ X: owed_c(o, a)_after >= owed_c(o, a)_before`
- **status:** not implemented.
- **why non-decreasing rather than equal:** a placement collects the position's pending fees into the
  order first, which raises the accumulator and so raises what every existing owner is owed. Only a
  decrease is a defect.
- **exactness:** exact for owners other than the placer. Their checkpoint and liquidity are both
  untouched and the accumulator only grows, so `owed` is monotonic with no truncation involved.
- **the placer's own case:** a placer topping up an existing share needs a wei of slack, and is worth
  asserting separately. The hook rewrites their checkpoint to preserve what they were owed, and that
  round trip divides by the new liquidity and multiplies back, so it can settle one wei low.
- **coverage dependency:** only meaningful on orders with more than one owner, which is
  `ghost_multipleOwnerCount`, currently about 4 of 22 orders per sequence. Worth raising the placement
  bias toward existing orders before trusting this one.

## S: system solvency

### INV-S-01: The hook holds every amount it owes

- **scope:** all orders, per currency
- **statement:** For each currency, the hook's ERC-6909 claim balance in the `PoolManager` covers the
  principal still recorded against every order plus the fees owed to each of their owners.
- **predicate:** `∀c: claims_c(hook) >= Σ_o [ principalCredited_c(o) + Σ_a owedFees_c(o,a) ]`, and the
  surplus is at most `ROUNDING_TOLERANCE`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- **why a bound rather than an equality:** both the accumulator credits and the payout shares truncate,
  so the claims run slightly ahead. The surplus is bounded separately, so a leak cannot hide behind the
  tolerance.
- **assumptions:** the hook receives claims only from its own callbacks. No donations, no third party
  minting claims to it.

## C: cancellation

### INV-C-01: An order id is reset only after the last canceller

- **scope:** unfilled orders
- **statement:** `cancelOrder` resets the order key to `ORDER_ID_DEFAULT` if and only if the call
  removes the last remaining owner from the order.
- **predicate:** `∀o: ¬filled(o) ⟹ ( keyRetired(o) ⟺ fullyCancelled(o) )`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- **why both directions matter:** the key is the only way `cancelOrder` addresses an order, so a retired
  key over an order that still has owners strands them permanently. A live key over an empty order is
  the reverse defect, addressable with nothing to cancel.
- **why unfilled only:** a fill retires the key while the liquidity is still recorded, so the two
  legitimately disagree for a filled order until every owner has withdrawn.
- **harness note:** `keyRetired` comes from `handler.orderIdWasRemoved`, which compares the key mapping
  against the order id, and `fullyCancelled` from the owner count. Neither reads `liquidityTotal`.
- **mutation checked:** relaxing the retirement condition from `liquidity == liquidityTotal` to
  `liquidity <= liquidityTotal`, so a partial cancel also retires the key, fails it within 30 runs.
- **coverage:** roughly 14 of the 27 orders in a sequence are unfilled and 12 fully cancel, so both
  sides are exercised.

### INV-C-03: A fully cancelled order holds no liquidity

- **scope:** orders every owner has cancelled out of
- **statement:** Once every owner of an unfilled order has cancelled, the order records no liquidity.
- **predicate:** `∀o: fullyCancelled(o) ⟹ liqTotal(o) == 0`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- **why it is a claim and not a restatement:** `fullyCancelled` is the handler's owner count and reads
  neither `liquidityTotal` nor `principalCredited`.

### INV-C-04: A fully cancelled order holds no principal

- **scope:** orders every owner has cancelled out of, per currency
- **statement:** Once every owner of an unfilled order has cancelled, the principal the order records
  is zero.
- **predicate:** `∀o: fullyCancelled(o) ⟹ principalCredited_c(o) == 0`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- **why it is stronger than it reads:** a cancelled order never filled and only a fill credits
  principal, so the correct value is not "paid out" but "never recorded". It fails if the cancel path
  writes to the principal ledger, which is the ledger mixing that H-01 was.
- **mutation checked:** adding `principalCredited0 += 1` to the cancel callback fails it while INV-C-03
  still passes.

### Liveness: every owner of an unfilled order can cancel their share

Covered indirectly, by form 2 below. Every guard is satisfied by assumption and the remaining failure
modes are other invariants: `liquidityTotal -= liquidity` underflows only if INV-F-01 is violated, and
`modifyLiquidity(-liquidity)` reverts only on a pool-versus-bookkeeping mismatch, which is INV-S-02.

## Harness notes

### Ghost state actually required

Only the exit invariants (INV-F-02, INV-F-03, INV-C-03, INV-C-04) need a ghost for their predicate,
because the contract records no notion of "every owner has left". Everything else is readable from
`getOrderInfo`, `getUserInfo`, and `getOrderId`.

- `ghost_orderIds` is **reachability**, not accounting. The hook retires ids from its key mapping, so a
  filled or cancelled order cannot be enumerated from live state at all.
- `ghost_wasFilled` / `ghost_wasFullyCancelled` / `ghost_wasFullyWithdrawn` scope the exit invariants
  and, through their counts, prove **coverage**. An invariant quantified over filled orders is vacuous
  while no order has filled, and a vacuous invariant reports `[PASS]`.
- All three derive from `ghost_activeOwners`, a membership count incremented on a first placement and
  decremented on a full exit. An earlier version compared sticky participant sets, which reported a full
  cancellation as soon as the canceller count matched the placer count, so an actor cancelling and
  placing again into the same live order tripped it.

### Coverage is asserted in `afterInvariant`

`afterInvariant` runs once at the end of each sequence, so it is the only place a coverage figure can be
read. An `invariant_` function runs after every call and once before the first, so a coverage assertion
placed there fails at setup on every campaign.

Every action and every quantified-over state is gated with `assertGt(_, 0)`, which makes each of the 500
sequences prove it reached the states the invariants speak about rather than proving it on average.

The gate is only sound when the state is reliably reachable. A per-sequence `assertGt` on something that
averages a handful of occurrences fails on the unlucky sequences, and once it trips Foundry shrinks the
sequence, so the counterexample is a one-call `placeOrder` that explains nothing. Full cancellation sat
at 3 per sequence and did exactly this, which drove the selection change below rather than a weaker
assertion.

Measured on a representative sequence of 200 calls:

| | count |
| --- | --- |
| orders created | 27 |
| filled | 13 |
| fully cancelled | 12 |
| fully withdrawn | 11 |
| placeOrder / cancelOrder / withdraw | 34 / 16 / 11 |
| swapTo / swapRoundTrip | 69 / 70 |

### Selection pressure on the exit paths

`cancelOrder` and `withdraw` used to discard roughly 90% of their generated calls, because each picked an
actor at random and gave up when that actor held no liquidity in the chosen order. With three actors and
an order typically having one or two owners, a random pick missed more often than it hit.

Both now rotate the actor set from the seed and take the first holder, via `_ownerFromSeed`. Full
cancellations went from 3 to 12 per sequence and orders created from 19 to 27, which is what makes the
coverage gates sound.

The remaining discard is inherent: `cancelOrder` still picks a `(tick, direction)` pair that may hold no
live order, and `withdraw` still needs its order to have filled.

## What this decomposition does not cover

- **INV-S-02: the pool position against the hook's bookkeeping.** The liquidity the `PoolManager`
  attributes to the hook's position at a tick, against the summed `liquidityTotal` of the active
  orders there. This is the one thing that can make a well-formed cancel or fill revert.

Also out of scope by construction: the campaign initializes one pool. The hook supports many, its order
ids come from a single global counter, and its claim balance is per currency rather than per pool, so two
pools sharing a currency draw on the same balance. Covering that is a second pool in `setUp`, not a change
to any invariant here.

## Liveness invariants

Claims of the form "every owner can withdraw" or "every owner can cancel" are liveness. A Foundry
invariant function evaluates a predicate over state at rest and cannot express them. Two ways to test
them:

1. **Restate as a safety predicate over the state that would make the call fail.** Stronger, because
   it names the mechanism rather than the symptom, and it shrinks to a smaller counterexample. Only
   available when the failure condition is expressible over readable state.
2. **Attempt the call.** `fail_on_revert = true` already provides this for every handler action,
   limited to the callers the fuzzer selects.

Both withdrawal and cancellation are covered by form 2. Neither has a failure condition worth restating:
the accumulator subtraction cannot underflow by construction, since the accumulators never decrease and a
checkpoint is only ever written at or below the accumulator it is read against.
