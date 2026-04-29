# Balancer V2 Invariants

Derived from `threat-model-final.md` and `function-notes.md`. These invariants are written as review anchors: each one should be testable by code inspection, targeted unit tests, fuzzing, or state-transition reasoning.

Factory- and pool-family-specific items are included where they directly affect accounting, fee debt, BPT valuation, read-only safety, or emergency exit semantics.

## Core Accounting Invariants

### 1. Vault custody coverage
Type: `accounting`
Priority: `critical`

Statement:
- For each supported token, the Vault’s actual token balance must cover all Vault-custodied liabilities, including pool cash balances and user internal balances, excluding explicitly managed balances and other protocol-defined non-custodied claims.

Why it matters:
- If Vault-held balances do not cover custody-side liabilities, joins, exits, swaps, flash loans, or internal-balance withdrawals can become undercollateralized.

Relevant mechanisms:
- `pkg/vault/contracts/PoolTokens.sol`
- `pkg/vault/contracts/balances/BalanceAllocation.sol`
- `pkg/vault/contracts/balances/TwoTokenPoolsBalance.sol`
- `pkg/vault/contracts/Swaps.sol`
- `pkg/vault/contracts/PoolBalances.sol`

What could break it:
- Internal accounting credits value not actually received by the Vault.
- Internal balances are debited or credited against the wrong user.
- Managed-balance updates are treated like cash without real backing.
- Non-standard token behavior is accepted under assumptions that only hold for standard ERC20 transfers.

Suggested checks:
- Join/exit/swap/flash-loan conservation tracing.
- `batchSwap` asset delta conservation fuzzing.
- Internal-balance sender/recipient isolation tests.

### 2. Pool-token balance identity
Type: `accounting`
Priority: `critical`

Statement:
- For each pool-token, `total = cash + managed`.
- `cashToManaged` and `managedToCash` must preserve `total`.
- `setManaged` is the only path that may change `total` without direct Vault token movement, and therefore defines the asset-manager trust boundary.

Why it matters:
- This is the core Balancer managed-balance abstraction. If it breaks, pool solvency and LP claims become ungrounded.

Relevant mechanisms:
- `pkg/vault/contracts/balances/BalanceAllocation.sol`
- `pkg/vault/contracts/balances/TwoTokenPoolsBalance.sol`
- `pkg/vault/contracts/AssetManagers.sol`

What could break it:
- Phantom profit reporting via `setManaged`.
- Hidden losses masked as managed balances.
- Incorrect packing or unpacking of `cash`, `managed`, or `lastChangeBlock`.
- Specialization-specific update helpers mutating total when only custody domain should change.

Suggested checks:
- `cash + managed` conservation invariants.
- Managed update tests with low-cash/high-managed exit scenarios.
- Two-token shared-packing correctness tests.

### 3. Cross-pool accounting isolation
Type: `accounting`
Priority: `critical`

Statement:
- A balance mutation for one pool-token must not change, unlock, or settle value belonging to another pool or another token, except through explicit Vault-supported net settlement paths.

Why it matters:
- The Vault is a shared settlement layer. Any `poolId` or token-index confusion can turn a local accounting bug into cross-pool value leakage.

Relevant mechanisms:
- `pkg/vault/contracts/PoolTokens.sol`
- `pkg/vault/contracts/balances/TwoTokenPoolsBalance.sol`
- `pkg/vault/contracts/balances/MinimalSwapInfoPoolsBalance.sol`
- `pkg/vault/contracts/balances/GeneralPoolsBalance.sol`
- `pkg/vault/contracts/Swaps.sol`

What could break it:
- PoolId/token-index mismatch.
- Two-token pair ordering/hash confusion.
- Shared settlement logic mutating the wrong pool’s balances.
- Batch netting across overlapping assets leaking value between pools.

Suggested checks:
- `poolId` / token-index mismatch tests.
- Two-token pair hash/order tests.
- Multi-pool `batchSwap` with overlapping assets.

### 4. Settlement conservation by path type
Type: `state transition`
Priority: `critical`

Statement:
- For normal swap/join/exit/flash-loan paths, Vault cash deltas must equal user settlement plus protocol-fee settlement.
- For Asset Manager paths, `cashToManaged` and `managedToCash` must preserve total, while `setManaged` is the only path that may explicitly change total without direct Vault token movement.

Why it matters:
- Balancer uses different accounting transitions for ordinary settlement and managed-balance mutation. Mixing them conceptually hides bugs.

Relevant mechanisms:
- `pkg/vault/contracts/PoolBalances.sol`
- `pkg/vault/contracts/Swaps.sol`
- `pkg/vault/contracts/FlashLoans.sol`
- `pkg/vault/contracts/AssetManagers.sol`
- `pkg/vault/contracts/balances/BalanceAllocation.sol`

What could break it:
- Pool callback returns economically inconsistent amounts.
- Sign confusion in `batchSwap` deltas.
- Fees settled on the wrong basis or in the wrong order.
- Asset-manager paths changing total where only custody-domain movement should happen.

Suggested checks:
- Path-by-path accounting traces.
- Join/exit where protocol fee exceeds nominal delta.
- Managed operation traces for withdraw/deposit/update.

## BPT and Share-Claim Invariants

### 5. BPT supply coherence
Type: `solvency`
Priority: `critical`

Statement:
- Pool balances as tracked by the Vault, together with the pool invariant and fee rules, must back BPT supply.
- Mint and burn quantities must remain coherent with invariant-based pricing after applying protocol fee rules.

Why it matters:
- Balancer BPT is not always a simple linear NAV claim. In weighted and composable designs, the invariant and fee debt matter directly.

Relevant mechanisms:
- `pkg/pool-utils/contracts/BalancerPoolToken.sol`
- `pkg/vault/contracts/PoolBalances.sol`
- `pkg/vault/contracts/PoolTokens.sol`
- `pkg/pool-weighted/contracts/WeightedMath.sol`
- `pkg/pool-weighted/contracts/BaseWeightedPool.sol`

What could break it:
- Mint before asset receipt is finalized.
- Burn after assets already leave the system.
- Protocol-fee debt not reflected in effective supply.
- Composable stable BPT-in-pool accounting counting the same economic claim twice.

Suggested checks:
- Join mint ordering test.
- Exit burn ordering test.
- Protocol fee dilution test.
- Composable stable effective-supply reconciliation.

### 6. Actual supply vs raw supply correctness
Type: `derived view`
Priority: `high`

Statement:
- Any valuation that depends on pool share supply must distinguish raw `totalSupply()` from effective supply that includes pending protocol-fee BPT debt.

Why it matters:
- Balancer share valuation is not always a direct function of ERC20 supply; pending fee debt changes the true claim base.

Relevant mechanisms:
- `pkg/pool-weighted/contracts/WeightedPool.sol`
- `pkg/pool-utils/contracts/BalancerPoolToken.sol`

What could break it:
- External consumers using `totalSupply()` where `getActualSupply()` is required.
- `getActualSupply()` being consumed during unsafe Vault context.
- Fee debt calculated against stale invariant or stale rate state.

Suggested checks:
- `totalSupply()` vs `getActualSupply()` differential tests.
- Read-only reentrancy test around actual-supply reads.
- Due-protocol-fee-adjusted BPT valuation tests.

## Swap and Math Invariants

### 7. Invariant-safe swap execution
Type: `math / pricing`
Priority: `critical`

Statement:
- Given pool math and configured fees, a round-trip or closed-cycle sequence executed against unchanged external conditions should not produce deterministic profit beyond expected rounding bounds.

Why it matters:
- This is the practical, testable economic safety property of the AMM.

Relevant mechanisms:
- `pkg/vault/contracts/Swaps.sol`
- `pkg/pool-weighted/contracts/BaseWeightedPool.sol`
- `pkg/pool-weighted/contracts/WeightedMath.sol`

What could break it:
- Wrong fee direction on exact-in/exact-out paths.
- Rounding bias that leaks value on repeated cycles.
- Stale scaled balances or stale weights.
- Violations of max in/out ratio bounds.

Suggested checks:
- Exact-in/exact-out roundtrip tests.
- Cyclic profitability fuzzing.
- Extreme imbalance invariant tests.

### 8. Scaling and rounding monotonicity
Type: `math / accounting`
Priority: `high`

Statement:
- Raw token amounts, scaled amounts, invariant-math amounts, and final transfers must preserve monotonicity without systematic leakage.
- For weighted math, `amountOut` should round down, `amountIn` should round up, and join-side BPT minting should not over-reward the caller.

Why it matters:
- Multi-asset AMMs frequently fail at scaling edges, not only in headline invariant formulas.

Relevant mechanisms:
- `pkg/pool-weighted/contracts/WeightedPool.sol`
- `pkg/pool-weighted/contracts/BaseWeightedPool.sol`
- `pkg/pool-weighted/contracts/WeightedMath.sol`
- `pkg/pool-weighted/contracts/managed/ManagedPoolTokenStorageLib.sol`
- `pkg/pool-stable/contracts/ComposableStablePool.sol`

What could break it:
- Decimal-difference packing mistakes.
- Asymmetric scaling between swap, join, exit, and fee logic.
- Single-token join/exit shortcuts differing from full-path math.
- Rate-provider-scaled assets drifting from invariant basis.

Suggested checks:
- Decimal scaling fuzz.
- Single-token vs full-array join equivalence tests.
- Stable / composable rate scaling differential tests.

### 9. Batch netting correctness
Type: `settlement`
Priority: `critical`

Statement:
- The sum of per-step `batchSwap` deltas must equal final `assetDeltas`, with sign convention preserved for every asset and settlement endpoint.

Why it matters:
- `batchSwap` is one of Balancer’s most distinctive and failure-prone surfaces.

Relevant mechanisms:
- `pkg/vault/contracts/Swaps.sol`

What could break it:
- Asset index mismatch.
- Sender/recipient confusion under relayer execution.
- Wrong sign handling on multihop settlement.
- Incorrect `amount == 0` sentinel propagation.

Suggested checks:
- Delta-conservation fuzzing.
- Multihop sentinel tests.
- Relayer redirect and internal-balance isolation tests.

## Reentrancy and Read-Only Safety Invariants

### 10. Callback sequencing coherence
Type: `reentrancy / ordering`
Priority: `critical`

Statement:
- During joins, exits, swaps, and flash loans, no external token transfer or callback may expose partially updated accounting that can be exploited for stale-balance usage, stale-fee usage, or share/accounting desynchronization.

Why it matters:
- Balancer’s architecture is callback-heavy and historically sensitive to read-only reentrancy and mixed-state observation.

Relevant mechanisms:
- `pkg/vault/contracts/PoolBalances.sol`
- `pkg/vault/contracts/Swaps.sol`
- `pkg/vault/contracts/FlashLoans.sol`
- `pkg/pool-utils/contracts/lib/VaultReentrancyLib.sol`

What could break it:
- Pool-side views callable during Vault context.
- External integrations consuming supply/rate/invariant during join/exit.
- Pool hooks or token callbacks observing new supply with stale balances.

Suggested checks:
- Read-only reentrancy tests on rate/invariant/supply functions.
- Mixed-state observation tests around joins/exits.
- External oracle-consumer mock exploit tests.

### 11. Oracle-unsafety under Vault context
Type: `integration safety`
Priority: `high`

Statement:
- Derived views such as rate, supply, invariant, and effective BPT valuation must not be treated as safe oracle inputs during inconsistent Vault context.

Why it matters:
- Even if Balancer itself does not lose funds directly, unsafe integration assumptions can turn transient internal state into external liquidation or collateral bugs.
- This is an integration-facing version of the callback sequencing invariant.

Relevant mechanisms:
- `pkg/pool-utils/contracts/lib/VaultReentrancyLib.sol`
- `pkg/pool-weighted/contracts/WeightedPool.sol`
- `pkg/pool-utils/contracts/BalancerPoolToken.sol`

What could break it:
- `getActualSupply()` or `getRate()` read during join/exit.
- Flash-loan-assisted state reads.
- Protocol fee debt excluded from rate/supply valuation.

Suggested checks:
- Read-only reentrancy rate manipulation test.
- External oracle-consumer mock exploit.
- Due-fee-adjusted valuation differential tests.

## Fee and Treasury Invariants

### 12. Protocol fee single-charge
Type: `fee accounting`
Priority: `high`

Statement:
- Swap fees, yield fees, and protocol fees must be charged exactly once and must not be bypassable through join/exit type, pool variant, token-set mutation, or stale cache behavior.

Why it matters:
- Fee bugs create silent value transfer between LPs, traders, and the protocol.

Relevant mechanisms:
- `pkg/pool-weighted/contracts/WeightedPool.sol`
- `pkg/pool-weighted/contracts/WeightedMath.sol`
- `pkg/pool-utils/contracts/factories/BasePoolFactory.sol`
- `pkg/pool-stable/contracts/ComposableStablePool.sol`

What could break it:
- Join before fee realization, exit after fee realization timing games.
- Stale rate-provider inputs in yield-fee logic.
- BPT-in-pool effective-supply mismeasurement.
- Cached fee state applied to the wrong invariant or supply base.

Suggested checks:
- Yield fee single-charge tests.
- Fee realization before/after join/exit differential tests.
- Composable fee-base measurement tests.

## Emergency and Privileged-Control Invariants

### 13. Recovery exit correctness
Type: `emergency path`
Priority: `high`

Statement:
- Recovery-mode exits must let users redeem a coherent proportional claim even when normal math, rate providers, or selected pool hooks are unsafe or paused.

Why it matters:
- Emergency controls are only useful if users can still leave safely.

Relevant mechanisms:
- `pkg/pool-utils/contracts/RecoveryMode.sol`
- `pkg/pool-utils/contracts/BasePool.sol`
- `pkg/pool-utils/contracts/RecoveryModeHelper.sol`
- `pkg/pool-weighted/contracts/BaseWeightedPool.sol`
- `pkg/pool-stable/contracts/ComposableStablePool.sol`
- Pool-family-specific recovery exit implementations

What could break it:
- Recovery depends on stale or reverting rate providers.
- Protocol fee debt blocks exitability.
- Recovery path uses wrong supply base.
- Pause disables one path but unsafe alternate entrypoints remain.

Suggested checks:
- Recovery proportional exit test.
- Recovery with broken rate provider.
- Recovery after protocol fee accrual.

### 14. Parameter schedule monotonicity
Type: `privileged control`
Priority: `high`

Statement:
- Weight ramps, amp ramps, token add/remove, fee changes, and pause-window behavior must respect configured bounds and monotonicity without creating instantaneous value transfer.

Why it matters:
- Privileged parameter motion is legitimate protocol behavior only if it remains bounded and non-extractive.

Relevant mechanisms:
- `pkg/pool-weighted/contracts/lbp/LiquidityBootstrappingPoolFactory.sol`
- `pkg/pool-weighted/contracts/managed/ManagedPoolFactory.sol`
- `pkg/pool-weighted/contracts/managed/ManagedPoolAddRemoveTokenLib.sol`
- `pkg/pool-weighted/contracts/managed/ManagedPoolTokenStorageLib.sol`
- `pkg/pool-stable/contracts/ComposableStablePool.sol`

What could break it:
- Ramp endpoints or times are mutable in unsafe ways.
- Token add/remove changes weights or ordering inconsistently.
- Pause-window time math is off-by-one or bypassable.
- Manager actions create trapped-fund states.

Suggested checks:
- Weight-ramp monotonicity fuzz.
- Amp-ramp discontinuity test.
- Token add/remove weight-sum invariant.

## Non-Invariants / Assumption Boundaries

- Asset Managers are trusted for the truthfulness of externally managed balances unless the reviewed scope states otherwise.
- Unsupported ERC20 behavior should not be escalated unless the token is explicitly supported or the code claims compatibility.
- Factory owner and pool owner powers may be trusted depending on pool family and deployment assumptions.
- External integrations are responsible for using Balancer rate/supply views safely unless Balancer documentation or helper contracts promise safe oracle behavior.
- Some privileged managed-pool transitions intentionally pass through invalid states; the invariant is that normal value-changing operations must be blocked or safely bounded during those states.

## Scope-Guided Priority

### P0
- Vault custody coverage
- Pool-token balance identity
- Cross-pool accounting isolation
- Settlement conservation by path type
- BPT supply coherence
- Invariant-safe swap execution
- Batch netting correctness
- Callback sequencing coherence

### P1
- Actual supply vs raw supply correctness
- Scaling and rounding monotonicity
- Oracle-unsafety under Vault context
- Protocol fee single-charge
- Recovery exit correctness
- Parameter schedule monotonicity
