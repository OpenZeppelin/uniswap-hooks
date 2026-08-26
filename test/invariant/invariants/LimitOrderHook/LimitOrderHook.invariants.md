# Invariant Spec: LimitOrderHook lifecycle

- **Target contract:** `src/general/LimitOrderHook.sol` (via `src/mocks/general/LimitOrderHookMock.sol`)
- **Campaign:** `LimitOrderHookInvariants.t.sol`
- **Status:** the `L`, `F`, `S` and `C` blocks hold. `P` (INV-P-01) is pending; no `A` invariants
  are designed yet.

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
  nor `principalCredited`.

### INV-F-02: A fully withdrawn order has no remaining principal

- **predicate:** `∀o: fullyWithdrawn(o) ⟹ principalCredited_c(o) == 0`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- Exact, no dust term: each withdrawal takes `mulDiv(P, l, L)` and the denominator shrinks alongside
  the numerator, so the last owner out has `l == L` and carries off every earlier remainder.
- The fee residual is out of scope: the last withdrawal deletes every `userInfo`, so no owed fees
  remain to compare against.

### INV-F-03: A filled order cannot be cancelled

- **predicate as tested:** `∀ active (t, d): ¬filled(orderId(t, d))`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- `cancelOrder` resolves the id from the key. Once `_fillOrder` retires the key, a filled order is
  unaddressable rather than guarded, and the revert is `ZeroLiquidity`.

## P: placement and fee entitlement

### INV-P-01: A first placement inherits no fees

- **predicate:** `owed_c(o, X) == 0` after `placeOrder`, given `liq(o, X) == 0` before
- **status:** not implemented.
- Transition property over a single `placeOrder`, to be asserted in the handler around the call.
- This is exactly H-01: entitlement begins at the placement, so any nonzero value is a transfer of
  the existing owners' fees to the new placer.
- Exact, no tolerance: a fresh owner has `liq == 0`, so the checkpoint is written at `acc` itself.
- Informative only on an order that already accrued fees; trivially true otherwise.

## S: system solvency

### INV-S-01: The hook holds every amount it owes

- **predicate:** `∀c: claims_c(hook) >= Σ_o [ principalCredited_c(o) + Σ_a owedFees_c(o,a) ]`, with
  the surplus at most `ROUNDING_TOLERANCE`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- A bound because credits and payout shares truncate. The surplus is bounded separately, so a leak
  cannot hide behind the tolerance.
- Assumes the hook receives claims only from its own callbacks: no donations, no third-party minting.

### INV-S-02: An action never reduces a non-caller's entitlement

- **predicate:** for every action by `X`: `∀(o, a), a ≠ X: entitlement_c(o, a)_after >= entitlement_c(o, a)_before`,
  where `entitlement_c(o, a) = owedFees_c(o, a) + mulDiv(principalCredited_c(o), liq(o, a), liqTotal(o))`
- **status:** **holds.** 3 runs, 900 calls, 0 reverts.
- Transition property, asserted in the handler around every action (the `stateTransition` modifier).
- The performing actor is exempt: exits collect their entitlement, and a top-up carries a wei of
  checkpoint truncation. Swaps exempt nobody.
- Exact for non-callers, no tolerance: their checkpoint and liquidity are untouched, the accumulators
  only grow, and a withdrawal leaves its principal truncation dust to the remaining owners.
- The handler recomputes entitlements from raw hook state (`getOrderInfo`, `getUserInfo`) rather
  than through `feesOwed`/`principalOwed`, so a broken view cannot vouch for itself.
- **mutation checked:** dropping the withdraw exemption fails immediately, so the assertion observes
  real entitlement movement.

## C: cancellation

### INV-C-01: An order id is reset only after the last canceller

- **predicate:** `∀o: ¬filled(o) ⟹ ( keyRetired(o) ⟺ fullyCancelled(o) )`
- **status:** **holds.** 500 runs, 100k calls, 0 reverts.
- Both directions matter: a retired key over an owned order strands the owners; a live key over an
  empty order is addressable with nothing to cancel.
- Unfilled only: a fill retires the key while the liquidity is still recorded.
- `keyRetired` compares the key mapping against the id, `fullyCancelled` is the handler's owner
  count. Neither reads `liquidityTotal`.
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
- **mutation checked:** adding `principalCredited0 += 1` to the cancel callback fails it.
