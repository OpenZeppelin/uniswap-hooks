# Invariant Spec: LimitOrderHook lifecycle

- **Target:** `src/general/LimitOrderHook.sol`, via `src/mocks/general/LimitOrderHookMock.sol`
- **Campaign:** `LimitOrderHookInvariants.t.sol`
- **Prefixes:** `L` live orders and price tracking, `F` the filled state, `P` placement and fee
  entitlement, `C` cancellation, `S` solvency, `A` access control.

An order id is **active** while `getOrderId` returns it, **filled** once `_fillOrder` sets `filled` and
retires the key in the same call, and **cancelled** when its key returns `ORDER_ID_DEFAULT` while
`filled` is false. A retired id is unreachable through the key mapping, so every invariant quantifies
over a handler-maintained id set.

`accFee_cPerLiqX128` only increases. Each owner holds a checkpoint `feeCheckpoint_cX128` and is owed
`mulDiv(acc_c - ckpt_c, liq, Q128)`. Principal is tracked separately as `principalCredited_c`, credited
once by the fill and split pro-rata.

## L: live orders and price tracking

### INV-L-01: An order's total liquidity equals the sum of its owners' liquidity

- `∀o: liqTotal(o) == Σ_{a ∈ actors} liq(o, a)`
- Holds. 500 runs, 100k calls.

### INV-L-02: An order is filled as soon as the price crosses its tick

- `∀ active (t, d): d ? tickLowerNow <= t : tickLowerNow >= t`, where
  `tickLowerNow = _getTickLower(storedTick, tickSpacing)`
- Holds. 10 runs, 5k calls.
- `storedTick` is `slot0.tick`, which is what `Pool.modifyLiquidity` branches on. Reading it rather
  than deriving from the price keeps the assertion independent of the hook's own derivation.

### INV-L-03: The recorded tick lower tracks the pool's stored tick

- `getTickLowerLast(poolId) == _getTickLower(storedTick, tickSpacing)`
- Holds. 10 runs, 5k calls.
- `_afterSwap` diffs the current tick against it, so drift leaves orders in the gap unfilled.

### INV-L-04: A live order holds its pool position alone

- `∀ live (t, d): positionLiquidity(hook, t, t + tickSpacing, salt(d)) == liqTotal(orderId(t, d))`
- Holds. 10 runs, 5k calls.
- Quantified over live orders only: a fill empties the position while `liquidityTotal` stays set until
  the withdrawals.
- Mutation checked: collapsing the position salt to `bytes32(0)` restores the shared position and
  fails it.

## F: the filled state

### INV-F-01: A fully withdrawn order holds no liquidity

- `∀o: fullyWithdrawn(o) ⟹ liqTotal(o) == 0`
- Holds. 500 runs, 100k calls.
- `fullyWithdrawn` is the handler's owner count, so this is not a restatement.

### INV-F-02: A fully withdrawn order has no remaining principal

- `∀o: fullyWithdrawn(o) ⟹ principalCredited_c(o) == 0`
- Holds. 500 runs, 100k calls.
- Exact, no dust term: the last owner out has `l == L` and carries off every earlier remainder.

### INV-F-03: A filled order cannot be cancelled

- `∀ active (t, d): ¬filled(orderId(t, d))`
- Holds. 500 runs, 100k calls.
- A filled order is unaddressable rather than guarded, since `_fillOrder` retires the key. The revert
  is `ZeroLiquidity`.

## P: placement and fee entitlement

### INV-P-01: A first placement inherits no fees

- `owed_c(o, X) == 0` after `placeOrder`, given `liq(o, X) == 0` before
- Not implemented.

### INV-P-02: A placement contributes only the currency the order sells

- For every `placeOrder` by `X` in direction `d`:
  `d ? (bal0(X) decreases ∧ bal1(X) unchanged) : (bal1(X) decreases ∧ bal0(X) unchanged)`
- Holds. 10 runs, 5k calls.
- Transition property, asserted in the handler around the call, against raw ERC-20 balances rather
  than hook state.
- Reaches the exact price boundary, where the pool counts a `zeroForOne` position as in range while
  `amount1` is zero. `ghost_boundaryPlacements` counts those, and the campaign fails if none occur.
- Mutation checked: removing `CrossedRange` from the place callback, with `_placeable` widened to
  offer wrong-side placements, fails it.

## S: system solvency

### INV-S-01: The hook holds every amount it owes

- `∀c: claims_c(hook) >= Σ_o [ principalCredited_c(o) + Σ_a owedFees_c(o,a) ]`, surplus at most
  `ROUNDING_TOLERANCE`
- Holds. 500 runs, 100k calls.
- A bound because credits and payout shares truncate. The surplus is bounded separately, so a leak
  cannot hide behind the tolerance.
- Assumes the hook receives claims only from its own callbacks.

### INV-S-02: An action never reduces a non-caller's entitlement

- For every action by `X`: `∀(o, a), a ≠ X: entitlement_c(o, a)_after >= entitlement_c(o, a)_before`,
  where `entitlement_c(o, a) = owedFees_c(o, a) + mulDiv(principalCredited_c(o), liq(o, a), liqTotal(o))`
- Holds. 3 runs, 900 calls.
- Transition property, asserted around every action. The performing actor is exempt, since exits
  collect their entitlement and a top-up carries a wei of checkpoint truncation. Swaps exempt nobody.
- Recomputed from raw hook state, so a broken view cannot vouch for itself.
- Mutation checked: dropping the withdraw exemption fails immediately.

## C: cancellation

### INV-C-01: An order id is reset only after the last canceller

- `∀o: ¬filled(o) ⟹ ( keyRetired(o) ⟺ fullyCancelled(o) )`
- Holds. 500 runs, 100k calls.
- Both directions matter: a retired key over an owned order strands the owners, a live key over an
  empty order is addressable with nothing to cancel.
- Mutation checked: retiring the key on a partial cancel fails within 30 runs.

### INV-C-03: A fully cancelled order holds no liquidity

- `∀o: fullyCancelled(o) ⟹ liqTotal(o) == 0`
- Holds. 500 runs, 100k calls.

### INV-C-04: A fully cancelled order holds no principal

- `∀o: fullyCancelled(o) ⟹ principalCredited_c(o) == 0`
- Holds. 500 runs, 100k calls.
- Only a fill credits principal, so the correct value is "never recorded", not "paid out".
- Mutation checked: adding `principalCredited0 += 1` to the cancel callback fails it.
