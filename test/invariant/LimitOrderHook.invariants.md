# Invariant Spec: LimitOrderHook

- **Target contracts:** `src/general/LimitOrderHook.sol` (via `src/mocks/general/LimitOrderHookMock.sol`)
- **Source of intent:** NatSpec on `LimitOrderHook` (contract-level doc + per-function
  doc), Uniswap v4 `PoolManager` / ERC-6909 claim semantics, `test/general/LimitOrderHook.t.sol`
  as a statement of expected behavior. The `docs/` tree holds only auto-generated API
  listings, so there is no separate prose spec.
- **Generated:** 2026-08-04 by invariant-generate
- **Status:** draft

> **Assumptions & caveats**
>
> - Single pool per campaign, standard ERC-20 currencies: no fee-on-transfer, no
>   rebasing, no native currency. `LimitOrderHook` never accounts for a transfer
>   shortfall, so a fee-on-transfer currency breaks solvency by construction and a
>   violation there would be expected, not a finding.
> - The `PoolManager` is trusted and correct. Invariants about hook-held value are
>   stated in terms of ERC-6909 claim balances read back from the `PoolManager`.
> - The hook receives ERC-6909 claims from **no source other than** its own
>   `placeOrder` / `cancelOrder` / `_fillOrder` paths. No donations to the hook, no
>   third party minting claims to it. INV-03 is only meaningful under this assumption.
> - External LPs may add liquidity to the same tick range, but their positions are keyed
>   by their own owner address, so they do not perturb the hook's position (INV-06).
> - Static pool fee; no dynamic-fee hook interaction.
> - `tick` arguments to `placeOrder` are assumed valid (multiple of `tickSpacing`, within
>   `TickMath` bounds). The contract documents this as a caller obligation, so
>   out-of-bounds ticks are out of scope.
> - "Active order" below means: an `orderKey` = `(key, tickLower, zeroForOne)` whose
>   `getOrderId` is not `ORDER_ID_DEFAULT`.
> - Notation: `total_c(o)` is `currency0Total`/`currency1Total` of order `o`;
>   `ckpt_c(o, a)` is actor `a`'s checkpoint for currency `c`; `liq(o, a)` is
>   `getOrderLiquidity(o, a)`; `liqTotal(o)` is `liquidityTotal`.

## INV-01: Order liquidity is fully attributed to owners

- **id:** INV-01
- **category:** conservation
- **priority:** high
- **statement:** For every order id ever created, the order's `liquidityTotal` equals the
  sum of per-owner `liquidity` entries across all actors. No liquidity is orphaned
  (unwithdrawable) and none is double-counted (over-withdrawable).
- **predicate:** `∀o: liqTotal(o) == Σ_{a ∈ actors} liq(o, a)`
- **touches:** `placeOrder`, `cancelOrder`, `withdraw`, `_fillOrder`
- **ghost:** `ghost_orderIds` — the set of every order id the handler has caused to be
  created (order ids are retired from the `_orderIds` mapping on fill/cancel-all, so the
  set cannot be recovered from public state).
- **how-to-test:** Track every created order id and the bounded actor set in the handler;
  in the invariant, loop `getOrderLiquidity(id, actor)` and compare the sum against
  `getOrderInfo(id).liquidityTotal`.
- **derivation:** Intent-derived. `liquidityTotal` is the divisor in `withdraw`'s
  pro-rata math, so it must be exactly the sum of the shares it divides among.
- **assumptions:** All liquidity enters and leaves through the handler's actor set, so no
  balance escapes it.

## INV-02: The hook can honor every recorded currency total

- **id:** INV-02
- **category:** solvency
- **priority:** high
- **statement:** For each currency, the hook's ERC-6909 claim balance held in the
  `PoolManager` is at least the sum of that currency's recorded totals across all orders.
  The hook can never owe order placers more currency than it actually holds.
- **predicate:** `∀c: poolManager.balanceOf(hook, c.toId()) >= Σ_{o ∈ ghost_orderIds} total_c(o)`
- **touches:** `_handlePlaceCallback`, `_handleCancelCallback`, `_handleWithdrawCallback`, `_fillOrder`
- **ghost:** `ghost_orderIds` (as INV-01).
- **how-to-test:** Read `IERC6909Claims(address(poolManager)).balanceOf(hook, currency.toId())`
  and compare with the summed `currency0Total` / `currency1Total` from `getOrderInfo`.
  Evaluate only at rest (between handler calls), never mid-unlock.
- **derivation:** Intent-derived. `withdraw` burns hook claims to pay out amounts computed
  from `currencyXTotal`; if the claim balance falls below the recorded totals, some user's
  withdrawal reverts and their funds are lost.
- **assumptions:** No claim source other than the hook's own callbacks; no fee-on-transfer.

## INV-03: No currency is permanently stranded in the hook

- **id:** INV-03
- **category:** conservation
- **priority:** high
- **statement:** The hook's claim balance is not merely sufficient but *exact*: it equals
  the sum of recorded currency totals. Any excess is value that was taken or minted on a
  user's behalf but is no longer attributed to any order, so no one can ever withdraw it.
- **predicate:** `∀c: poolManager.balanceOf(hook, c.toId()) == Σ_{o ∈ ghost_orderIds} total_c(o)`
- **touches:** `placeOrder`, `cancelOrder` (the `removingAllLiquidity` branch resets
  `currency0Total`/`currency1Total` to zero), `_fillOrder`, `_handleWithdrawCallback`
- **ghost:** `ghost_orderIds` (as INV-01).
- **how-to-test:** Same read as INV-02 with equality. **The harness must be able to reach
  the fee-credit-then-final-cancel sequence or this invariant is vacuous.** Minimal
  reaching sequence, single actor: `placeOrder` → fee-generating swap → `placeOrder` again
  at the same tick (the second `_handlePlaceCallback` takes `feesAccrued` as claims to the
  hook and returns them, so `currencyXTotal` becomes non-zero) → `cancelOrder`, which is
  `removingAllLiquidity` because the actor holds all of it. The multi-actor variant
  (partial cancel realizes fees, final cancel wipes them) is the same bug on a different
  path; drive both. Concretely this requires the handler to place repeatedly at an
  already-active tick, and to swap between places.
- **derivation:** Intent-derived from the contract's stated fee policy ("the accrued fees
  are added to the order info, benefitting the remaining limit order placers") — fees
  credited to an order must remain claimable by someone. Deliberately stated as equality
  rather than the weaker INV-02 so that leaks, not just insolvency, are caught.
- **assumptions:** As INV-02. A violation of magnitude 1–2 wei is rounding, not a leak;
  larger gaps are real.

## INV-11: A retired order leaves no unredeemable residual

- **id:** INV-11
- **category:** conservation
- **priority:** high
- **statement:** When an order becomes permanently unreachable — its key reset to
  `ORDER_ID_DEFAULT` while `filled` is false, so neither `cancelOrder` (key gone) nor
  `withdraw` (`NotFilled`) can ever touch it again — the currency credited to that order
  over its lifetime must have been fully paid out. No order may be retired holding a
  balance that no call can redeem.
- **predicate:** `∀o: retired(o) ∧ ¬filled(o) ⟹ ghost_credited_c(o) == ghost_paidOut_c(o)`
  for each currency, where `retired(o)` means `o` was once active and its key now maps to
  `ORDER_ID_DEFAULT`
- **touches:** `cancelOrder` (the `removingAllLiquidity` state reset), `_handleCancelCallback`,
  `_handlePlaceCallback` (fee credit), `_fillOrder`
- **ghost:** `ghost_credited[o][c]` — cumulative fee amounts credited into the order's
  totals, accumulated in the handler from the `amount0Fee`/`amount1Fee` deltas observed on
  `getOrderInfo` across each `placeOrder`/`cancelOrder`; `ghost_paidOut[o][c]` — cumulative
  currency actually delivered to an actor on that order's behalf, measured as actor balance
  deltas; `ghost_retired[o]` — sticky flag set when an order's key returns to
  `ORDER_ID_DEFAULT`.
- **how-to-test:** After every handler call, detect keys whose order id just went back to
  `ORDER_ID_DEFAULT` and record whether `filled` was true at that moment. In the invariant,
  assert the equality for every retired-and-unfilled order. Reaching sequence as INV-03.
- **derivation:** Intent-derived from the documented lifecycle: an order is either
  cancellable ("at any time until they are filled") or withdrawable ("once completely
  filled"). A state that is neither is outside the documented state machine, and any value
  sitting in it is lost. This is the sharp, per-order form of INV-03: INV-03 detects that
  the hook holds unattributed value, INV-11 names the order that leaked it and how much.
- **assumptions:** As INV-02/INV-03. Tolerate 1–2 wei of `mulDiv` rounding residual; a
  residual on the order of the accrued fees is the bug.

## INV-12: A fully-drained order holds no residual currency

- **id:** INV-12
- **category:** conservation
- **priority:** high
- **statement:** Once an order's `liquidityTotal` reaches zero, its currency totals must be
  zero too (up to rounding dust). With no liquidity left, `withdraw` reverts on
  `ZeroLiquidity` for every actor and `cancelOrder` cannot reach the order, so any
  remaining `currencyXTotal` is unredeemable.
- **predicate:** `∀o: liqTotal(o) == 0 ⟹ total_c(o) <= DUST` for each currency
- **touches:** `withdraw` (checkpoint subtraction leaves the excluded amount behind),
  `cancelOrder`, `_fillOrder`
- **ghost:** `ghost_orderIds` (as INV-01).
- **how-to-test:** Loop the known order ids; whenever `liquidityTotal == 0`, assert both
  totals are within `DUST`. Reaching sequence: actor A places, fee-generating swap, actor B
  places at the same tick (B's checkpoint is now non-zero), swap fills the order, then
  **both** A and B withdraw. The residual is the amount B's checkpoint excluded, which no
  further call can release.
- **derivation:** Intent-derived from the documented lifecycle. Complements INV-11, which
  covers the retired-and-unfilled cancel path; this one covers the drained-and-filled
  withdraw path. The two together assert that an order cannot end its life holding value,
  by either exit route.
- **assumptions:** As INV-02. `DUST` should be a small absolute tolerance (single-digit wei)
  for `mulDiv` truncation, not a proportional one. A residual on the order of the accrued
  fees is the bug, not rounding. Pick `DUST` deliberately: too generous and it hides the
  finding, too tight and every run fails on truncation noise.

## INV-04: Aggregate withdrawal entitlement never exceeds the order's totals

- **id:** INV-04
- **category:** arithmetic
- **priority:** high
- **statement:** For any filled order, the sum over all remaining owners of the amount
  `withdraw` would pay them never exceeds the currency the order actually holds. The
  checkpoint mechanism must not let the sum of individual claims exceed the pot.
- **predicate:** `∀o filled, ∀c: Σ_{a: liq(o,a)>0} mulDiv(total_c(o) − ckpt_c(o,a), liq(o,a), liqTotal(o)) <= total_c(o)`
- **touches:** `withdraw`, `placeOrder` (checkpoint write), `_fillOrder`
- **ghost:** `ghost_orderIds`; per-order, per-actor checkpoint mirror `ghost_ckpt[o][a][c]`
  written in the handler at the moment `placeOrder` succeeds (the contract exposes no
  checkpoint getter).
- **how-to-test:** Compute each remaining owner's payout with `FullMath.mulDiv` using the
  *current* `total_c` and `liqTotal`, sum, and compare. Requires multi-actor orders with
  staggered `placeOrder` calls around fee-generating swaps so checkpoints differ.
- **derivation:** Intent-derived from the documented anti-skim goal ("the user is not able
  to withdraw funds that were accrued before their checkpoint"). Note the predicate is
  evaluated against present state; because `withdraw` decrements both `total_c` and
  `liqTotal`, sequential withdrawals must also be exercised (see INV-05).
- **assumptions:** No owner has an outstanding partially-applied withdrawal (holds at rest).

## INV-05: Every remaining owner of a filled order can still withdraw

- **id:** INV-05
- **category:** arithmetic
- **priority:** high
- **statement:** For a filled order, the currency still recorded against the order is at
  least each remaining owner's checkpoint. Otherwise `total_c − ckpt_c` underflows and
  that owner's `withdraw` reverts permanently, stranding their principal.
- **predicate:** `∀o filled, ∀c, ∀a with liq(o,a) > 0: total_c(o) >= ckpt_c(o,a)`
- **touches:** `withdraw`, `placeOrder` (checkpoint write)
- **ghost:** `ghost_ckpt[o][a][c]` (as INV-04).
- **how-to-test:** After each `withdraw`, assert the predicate over the remaining owners.
  **Confirmed reachable** by the campaign in `LimitOrderHookInvariants.t.sol`: 23 runs,
  shrunk to 7 calls, violation `274644278 < 411854339` on `currency0Total`. The reaching
  sequence needs no `cancelOrder` and no lopsided liquidity: A places, one swap moves the
  price into the range and a second moves it back out (fees accrue, no fill), then B
  places. B's own call realizes those fees into `total_c`, but B's checkpoint was
  snapshotted at `placeOrder:284` before the credit at `placeOrder:308`, so B's checkpoint
  is zero. A places again and inherits the realized total as A's checkpoint. A fill plus
  B's withdrawal then drops `total_c` below A's checkpoint. Any `place → swap through →
  place` cycle realizes fees, so the skew needs only two actors behaving normally.
- **derivation:** Intent-derived. The contract documents cancel/withdraw as always
  available to a placer ("orders can be cancelled at any time until they are filled";
  once filled "the resulting liquidity can be withdrawn"), so a reachable state in which
  a placer's `withdraw` always reverts contradicts intent.
- **assumptions:** Actor set is fully controlled by the handler.

## INV-06: The pool position matches the hook's recorded liquidity

- **id:** INV-06
- **category:** conservation
- **priority:** high
- **statement:** For every tick the handler has touched, the liquidity the `PoolManager`
  attributes to the hook's position `[tickLower, tickLower + tickSpacing]` equals the sum
  of `liquidityTotal` over the active orders at that tick (both `zeroForOne` directions
  share a single pool position, since the position key does not include direction).
- **predicate:** `∀t ∈ ghost_ticks: getPositionLiquidity(poolId, key(hook, t, t+spacing, 0)) == Σ_{d ∈ {true,false}} liqTotalOfActiveOrder(t, d)`
- **touches:** `_handlePlaceCallback`, `_handleCancelCallback`, `_fillOrder`
- **ghost:** `ghost_ticks` — every `tickLower` the handler has placed an order at.
- **how-to-test:** `Position.calculatePositionKey(address(hook), t, t + tickSpacing, 0)`
  then `StateLibrary.getPositionInfo`. Sum `getOrderInfo(getOrderId(key, t, d)).liquidityTotal`
  for both directions, treating `ORDER_ID_DEFAULT` as zero.
- **derivation:** Intent-derived: an order's bookkeeping is a claim on pool liquidity, so
  the two must agree. The both-directions summation is **implementation-derived** — it
  encodes the fact that the hook shares one pool position between the two directions at a
  tick. Flag for review: if the intended design is one position per direction, this
  aggregation hides a collision rather than testing for it.
- **assumptions:** No external actor holds a position owned by `address(hook)`.

## INV-07: Active orders are unfilled

- **id:** INV-07
- **category:** state-machine
- **priority:** high
- **statement:** An order reachable through the `_orderIds` mapping is never already
  filled. A filled order must be unreachable so that new `placeOrder` calls allocate a
  fresh order id instead of joining a settled one.
- **predicate:** `∀ active o: getOrderInfo(o).filled == false`
- **touches:** `_fillOrder` (sets `filled`, retires the id), `cancelOrder`, `placeOrder`
- **ghost:** none — evaluable from `getOrderId` and `getOrderInfo` over the tick and
  direction set.
- **how-to-test:** For every candidate tick and direction, resolve `getOrderId`; when it is
  not `ORDER_ID_DEFAULT`, assert the order is not filled. What this really tests is that
  `_fillOrder` retires the key on the same path that sets the flag.
- **derivation:** Intent-derived. Joining a filled order would let a new placer draw on
  currency that belongs to the original placers.
- **assumptions:** None.

> A previous revision of this invariant carried a second conjunct, that `filled` never
> returns to false, backed by a sticky ghost. It was dropped: `filled` has exactly one
> write site (`_fillOrder`) and it writes `true`, so no reachable path can unset it and no
> campaign can produce a counterexample. Reading the contract settles it faster than
> fuzzing can.

## INV-08: No active order remains on the wrong side of the current price

- **id:** INV-08
- **category:** state-machine
- **priority:** high
- **statement:** After any swap, no active order remains whose range the price has already
  moved past. A `zeroForOne` order at `t` must not still be active once the current tick
  lower is above `t`; a `!zeroForOne` order at `t` must not still be active once the
  current tick lower is below `t`.
- **predicate:** `∀ active (t, d): d ? tickLowerNow <= t : tickLowerNow >= t`, where
  `tickLowerNow = _getTickLower(currentTick, tickSpacing)`
- **touches:** `_afterSwap`, `_getCrossedTicks`, `_fillOrder`, `_tickLowerLasts`
- **ghost:** none — evaluable from `getSlot0` plus `getOrderId` over `ghost_ticks`.
- **how-to-test:** Drive swaps of varying size and direction, including swaps that cross
  many tick spacings in one call and swaps that reverse direction, then evaluate the
  predicate over every tick in `ghost_ticks`. A violation means a missed fill: the placer
  keeps in-range liquidity and eats impermanent loss instead of being filled at their
  limit price.
- **derivation:** Intent-derived from the contract NatSpec: orders "will be filled if the
  pool's price crosses the order's tick". The exact tick-lower threshold is aligned with
  `_getCrossedTicks`, so treat an off-by-one-tick-spacing failure as a spec question
  before calling it a bug.
- **assumptions:** Fills happen only via `afterSwap`; no other path moves the price.

## INV-09: Order id allocation is injective and monotonic

- **id:** INV-09
- **category:** state-machine
- **priority:** medium
- **statement:** Order ids are handed out strictly increasing from 1, `ORDER_ID_DEFAULT`
  (0) is never an active id, and no two distinct active order keys map to the same order
  id.
- **predicate:** `(ids strictly increase) ∧ (∀ active keys k1 ≠ k2: orderId(k1) ≠ orderId(k2))`
- **touches:** `placeOrder`, `_setOrderId`, `getOrderId`
- **ghost:** `ghost_seenIds` — the set of ids observed as freshly allocated, plus the last
  allocated id for the monotonicity check.
- **how-to-test:** In the handler, after each `placeOrder`, read the resulting order id and
  assert it is either an already-known id for that key or strictly greater than every id
  seen so far. In the invariant, check pairwise distinctness over the active keys.
- **derivation:** Implementation-derived — `unsafeIncrement` is explicitly documented as
  possibly overflowing, so the monotonicity clause holds only below `2^232` allocations
  and cannot realistically be falsified by a campaign. Reviewer should consider dropping
  the monotonicity clause and keeping only the injectivity clause, which is the part that
  matters (id collision would merge two unrelated orders' funds).
- **assumptions:** Fewer than `2^232` orders placed.

## INV-10: An owner's liquidity is only reduced by that owner

- **id:** INV-10
- **category:** access-control
- **priority:** high
- **statement:** A given actor's per-order liquidity entry decreases only in a call where
  that actor was `msg.sender`. No other actor can cancel or withdraw someone else's
  position, and the `to` argument never lets a caller move another actor's liquidity.
- **predicate:** `∀o, ∀a: liq(o,a) decreased ⟹ msg.sender == a`
- **touches:** `cancelOrder`, `withdraw`
- **ghost:** `ghost_liq[o][a]` — mirror of the per-owner liquidity, compared before and
  after each handler call.
- **how-to-test:** Snapshot `getOrderLiquidity` for all actors on all known order ids
  before the call, compare after, and assert that any actor whose value dropped is the
  pranked sender. Include handler actions where actor X calls `cancelOrder`/`withdraw`
  with `to` set to actor Y.
- **derivation:** Intent-derived: "cancelling an order will cancel the order placed by the
  msg.sender, not orders placed by other users in the same tick range."
- **assumptions:** None. Note this permits the *proceeds* to be directed to an arbitrary
  `to`, which is by design.
