# Invariant Spec: LimitOrderHook lifecycle

- **Target contract:** `src/general/LimitOrderHook.sol` (via `src/mocks/general/LimitOrderHookMock.sol`)
- **Campaign:** `LimitOrderHookInvariants.t.sol`
- **Status:** the `L`, `F`, `S` and `C` blocks hold. The `P` and `A` blocks are pending.

> **Terminology.** An order carries one flag, `filled`, written only by `_fillOrder`. An order id is
> **active** while `getOrderId` returns it (implies `filled == false`), **filled** when
> `filled == true` (`_fillOrder` retires the key in the same call), and **cancelled** when its key
> returns `ORDER_ID_DEFAULT` while `filled` is false, which only the cancel of the last liquidity
> produces. A retired id is unreachable through the key mapping, so every invariant quantifies over a
> handler-maintained id set.

> **Prefixes.** `L` live orders and price tracking, `F` the filled state, `P` placement and fee
> entitlement, `C` cancellation, `S` solvency, `A` access control.

> **Fee accounting.** `accFee_cPerLiqX128` only ever increases. Each owner holds a checkpoint
> `feeCheckpoint_cX128` and is owed `mulDiv(acc_c - ckpt_c, liq, Q128)`. Principal is tracked
> separately as `principalCredited_c`, credited once by the fill and split pro-rata.

## L: live orders and price tracking

### INV-L-01: An order's total liquidity equals the sum of its owners' liquidity

- **predicate:** `∀o: liqTotal(o) == Σ_{a ∈ actors} liq(o, a)`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- The actor set is complete: the handler pranks every `placeOrder` as one of its own actors.

### INV-L-02: An order is filled as soon as the price crosses its tick

- **predicate:** `∀ active (t, d): d ? tickLowerNow <= t : tickLowerNow >= t`, where
  `tickLowerNow = _getTickLower(currentTick, tickSpacing)`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- `tickLowerNow` is computed from the pool price, never from `getTickLowerLast`, so a drifted tracker
  cannot make this agree with itself.

### INV-L-03: The recorded tick lower tracks the pool price

- **predicate:** `getTickLowerLast(poolId) == _getTickLower(currentTick, tickSpacing)`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- `_afterSwap` diffs the current tick against it, so drift leaves orders in the gap unfilled.

## F: the filled state

### INV-F-01: A fully withdrawn order holds no liquidity

- **predicate:** `∀o: fullyWithdrawn(o) ⟹ liqTotal(o) == 0`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- Not a restatement: `fullyWithdrawn` is the handler's owner count and reads neither `liquidityTotal`
  nor `principalCredited`. Deriving it from `liquidityTotal == 0` made this a tautology.

### INV-F-02: A fully withdrawn order has no remaining principal

- **predicate:** `∀o: fullyWithdrawn(o) ⟹ principalCredited_c(o) == 0`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- Exact, no dust term: each withdrawal takes `mulDiv(P, l, L)` and the denominator shrinks alongside
  the numerator, so the last owner out has `l == L` and carries off every earlier remainder.
- Does not cover the fee residual: the last withdrawal deletes every `userInfo`, so only INV-S-01's
  surplus bound observes it.

### INV-F-03: A filled order cannot be cancelled

- **predicate as tested:** `∀ active (t, d): ¬filled(orderId(t, d))`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- `cancelOrder` resolves the id from the key. Once `_fillOrder` retires the key, a filled order is
  unaddressable rather than guarded, and the revert is `ZeroLiquidity`.

## P: placement and fee entitlement

Both are transition properties over a single `placeOrder`, which an `invariant_` function cannot
express, so they are asserted in the handler around the call. Both recompute
`owed_c(o, a) = mulDiv(acc_c(o) - ckpt_c(o, a), liq(o, a), Q128)`, since the hook exposes no view.

Together they bracket H-01: an absolute checkpoint entitles a placer to prior fees (INV-P-01), a
checkpoint at `acc` forfeits what they were owed (INV-P-02). `ckpt_new = acc - owed/liqNew` is the
only value satisfying both.

### INV-P-01: A first placement inherits no fees

- **predicate:** `owed_c(o, X) == 0` after `placeOrder`, given `liq(o, X) == 0` before
- **status:** not implemented.
- Exact: a fresh owner has `liq == 0`, so the checkpoint is written at `acc` itself.
- Informative only on an order that already accrued fees; trivially true otherwise.

### INV-P-02: A placement does not reduce another owner's fees

- **predicate:** `∀a ≠ X: owed_c(o, a)_after >= owed_c(o, a)_before`
- **status:** subsumed by INV-S-02, which generalizes it over every action and adds the principal.
- Non-decreasing rather than equal: a placement collects the position's pending fees into the order
  first, which raises every owner's entitlement.
- Exact for other owners. The placer's own top-up needs a wei of slack, since the checkpoint rewrite
  divides by the new liquidity and multiplies back.
- Only meaningful on multi-owner orders; raise the placement bias before trusting it.

## S: system solvency

### INV-S-01: The hook holds every amount it owes

- **predicate:** `∀c: claims_c(hook) >= Σ_o [ principalCredited_c(o) + Σ_a owedFees_c(o,a) ]`, with
  the surplus at most `ROUNDING_TOLERANCE`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- A bound because credits and payout shares truncate. The surplus is bounded separately, so a leak
  cannot hide behind the tolerance.
- Assumes the hook receives claims only from its own callbacks: no donations, no third-party minting.

### INV-S-02: An action never reduces a non-participant's entitlement

- **predicate:** for every action by `X`: `∀(o, a), a ≠ X: entitlement_c(o, a)_after >= entitlement_c(o, a)_before`,
  where `entitlement_c(o, a) = owedFees_c(o, a) + mulDiv(principalCredited_c(o), liq(o, a), liqTotal(o))`
- **status:** **holds.** 3 runs, 900 calls, 0 reverts.
- Transition property, asserted in the handler around every action (`assertMonotonicEntitlements`).
  S-01 says the total covers everyone; this says nobody's share is taken by someone else's action.
- The performing actor is exempt: exits collect their entitlement, and a top-up carries a wei of
  checkpoint truncation. Swaps exempt nobody.
- Exact for non-participants, no tolerance: their checkpoint and liquidity are untouched, the
  accumulators only grow, and a withdrawal leaves its principal truncation dust to the remaining
  owners.
- The handler recomputes entitlements from raw hook state (`getOrderInfo`, `getUserInfo`) rather
  than through `feesOwed`/`principalOwed`, so a broken view cannot vouch for itself.
- Subsumes INV-P-02 and extends it to cancels, withdrawals and swaps. INV-P-01 remains separate:
  monotonicity says nothing about the joiner, whose prior entitlement is zero.
- **mutation checked:** dropping the withdraw exemption fails immediately, so the assertion
  observes real entitlement movement.

## C: cancellation

### INV-C-01: An order id is reset only after the last canceller

- **predicate:** `∀o: ¬filled(o) ⟹ ( keyRetired(o) ⟺ fullyCancelled(o) )`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- Both directions matter: a retired key over an owned order strands the owners; a live key over an
  empty order is addressable with nothing to cancel.
- Unfilled only: a fill retires the key while the liquidity is still recorded.
- `keyRetired` comes from `orderIdWasRemoved`, `fullyCancelled` from the owner count. Neither reads
  `liquidityTotal`.
- **mutation checked:** retiring the key on a partial cancel (`liquidity <= liquidityTotal`) fails
  within 30 runs.

### INV-C-03: A fully cancelled order holds no liquidity

- **predicate:** `∀o: fullyCancelled(o) ⟹ liqTotal(o) == 0`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- Not a restatement: `fullyCancelled` is the handler's owner count.

### INV-C-04: A fully cancelled order holds no principal

- **predicate:** `∀o: fullyCancelled(o) ⟹ principalCredited_c(o) == 0`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- Only a fill credits principal, so the correct value is "never recorded", not "paid out". Fails if
  the cancel path writes to the principal ledger.
- **mutation checked:** `principalCredited0 += 1` in the cancel callback fails it while INV-C-03
  still passes.

### Liveness: every owner of an unfilled order can cancel their share

Covered by form 2 below. The remaining failure modes are other invariants: the `liquidityTotal`
underflow is INV-L-01, the `modifyLiquidity` revert is INV-S-03.

## Harness notes

### Ghost state actually required

Only the exit invariants (INV-F-01, INV-F-02, INV-C-03, INV-C-04) need a ghost, because the contract
records no notion of "every owner has left". Everything else is readable from `getOrderInfo`,
`getUserInfo`, and `getOrderId`.

- `ghost_orderIds` is reachability, not accounting: retired ids cannot be enumerated from live state.
- The sticky flags scope the exit invariants and, through their counts, prove coverage. An invariant
  quantified over an unreached state is vacuous and reports `[PASS]`.
- All derive from `ghost_activeOwners`, a membership count. Comparing sticky participant sets
  misfired when an actor cancelled and re-placed into the same live order.

### Coverage is asserted in `afterInvariant`

`afterInvariant` runs once per sequence, the only place a coverage figure is readable (`invariant_`
functions also run before the first call). Every action and quantified-over state is gated with
`assertGt(_, 0)`, so each sequence proves it reached the states the invariants speak about.

The gate is only sound for reliably reachable states: a gate on a rare state fails on unlucky
sequences and shrinks to a meaningless counterexample. Full cancellation did exactly this at 3 per
sequence, which drove the selection change below rather than a weaker assertion.

Representative 200-call sequence: 27 orders created, 13 filled, 12 fully cancelled, 11 fully
withdrawn; 34 placeOrder, 16 cancelOrder, 11 withdraw, 69 swapTo, 70 swapRoundTrip.

### Selection pressure on the exit paths

`cancelOrder` and `withdraw` used to pick an actor at random and discard ~90% of generated calls.
Both now rotate the actor set from the seed and take the first holder (`_ownerFromSeed`); full
cancellations went from 3 to 12 per sequence. The remaining discard is inherent: a key may hold no
live order, and `withdraw` needs a filled one.

## Not covered

- **INV-S-03:** the pool's position against the hook's bookkeeping, the one thing that can make a
  well-formed cancel or fill revert.
- Multi-pool interactions: order ids come from one global counter and claims are per currency, so two
  pools sharing a currency draw on the same balance. Covering it is a second pool in `setUp`, not a
  change to any invariant here.

## Liveness invariants

"Every owner can withdraw/cancel" is liveness, which an invariant function cannot express. Two forms:

1. Restate as a safety predicate over the state that would make the call fail. Stronger, but only
   available when that state is readable.
2. Attempt the call, which `fail_on_revert = true` provides for every handler action.

Both exits are covered by form 2. Neither has a failure condition worth restating: the accumulators
never decrease and a checkpoint is only written at or below the accumulator it is read against, so
the subtraction cannot underflow.
