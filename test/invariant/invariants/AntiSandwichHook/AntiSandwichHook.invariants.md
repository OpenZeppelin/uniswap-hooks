# Invariant Spec: AntiSandwichHook

- **Target:** `src/general/AntiSandwichHook.sol`, via `src/mocks/general/AntiSandwichMock.sol`
- **Campaign:** `AntiSandwichHookInvariants.t.sol`
- **Prefix:** `INV`

The hook records the pool price before each block's first swap. Valued at that price, a later swap in the
block may not receive more than it paid. `slack` is the one unit the bound can leave to the swapper above a
square root price of `2**128`.

## INV-01: A swap is never filled better than the beginning-of-block price

- Buying currency0: `paid1 + slack >= received0 * price`. Selling: `received1 <= paid0 * price + slack`.
- Asserted after every swap.

## INV-02: The checkpoint changes only when a new block claims it

- `checkpoint_after != checkpoint_before` implies `blockNumber_after == block.number` and
  `blockNumber_before != block.number`

## INV-03: No sandwich ends a block ahead

- `value_after - value_before <= 2 * slack` for a front run, a victim and a back run in one block, in both
  directions, valued in currency1 at the block's price.
- The own-book arm repeats the plan with the attacker supplying the liquidity and measures the difference, so
  what a provider earns cancels.

## INV-04: The first swap of a block pays no fee

- `fee == 0` for the first swap of a block

## INV-05: The hook never rejects a swap the pool accepted

- No revert wrapped in `CustomRevert.WrappedError` names the hook.
- `TargetOutOfRange` and `CheckpointNotSet` are deliberate and lie outside the campaign's range.

## INV-06: The checkpoint never claims a future block

- `checkpoint.blockNumber <= block.number`

## INV-07: A checkpoint that claims the current block holds a price

- `checkpoint.blockNumber == block.number` implies `checkpoint.sqrtPriceX96 != 0`

## INV-08: Every fee reaches the recipient, and none rests in the hook

- `claims_c(recipient) == sum of fees taken in c` and `claims_c(hook) == 0`, for both currencies

## INV-09: The checkpoint refresh is bounded

- `gas of a block's first swap < 1_000_000`, however far the price moved since the last block
