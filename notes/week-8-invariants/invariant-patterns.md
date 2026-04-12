# Invariant Patterns

## 1. Conservation / boundedness

Question:
What value should not grow or shrink without an explicit path?

Typical use:
- asset/share systems
- vault accounting
- lending pool liquidity
- protocol-wide value conservation checks

What to look for:
- total user claims should not systematically exceed protocol-supported value
- total borrow should not exceed what the system can account for
- no value should appear or disappear without a transfer, fee, pnl realization, liquidation, or explicit bad-debt crystallization path

Common mistake:
- writing a naive “sum of everything must be constant” invariant when interest accrual, fee minting, or unlock logic legitimately changes totals

Examples from Week 8:
- Morpho: `totalBorrowAssets <= totalSupplyAssets` as a first market-level recorded bound
- Yearn: no-op honest report should not shift claims or total supply
- Perennial: local collateral delta should not have unexplained residual outside known settlement components

## 2. Solvency / health

Question:
What state should never be considered healthy/unhealthy incorrectly?

Typical use:
- lending
- margin systems
- liquidation systems
- collateralized vaults

What to look for:
- healthy positions should not be liquidatable
- unhealthy positions should not remain incorrectly protected
- withdrawals / borrows should not leave the account in an invalid state while still succeeding
- bad debt should only appear through a defined insolvency path

Design note:
The most useful first version is often not a full health-formula invariant, but a narrower precondition invariant.

Common mistake:
- trying to reimplement the full protocol health function too early
- writing a mathematically elegant invariant that is harder to trust than the protocol’s own semantics

Examples from Week 8:
- Morpho: successful liquidation requires existing debt
- Morpho: successful liquidation requires existing collateral
- Morpho lesson: liquidation precondition invariants can be more robust than forcing a full external health check too early

## 3. Monotonicity

Question:
What should only move in one direction?

Typical use:
- unlock schedules
- cumulative indices
- interest accumulators
- version/checkpoint progression

What to look for:
- unlocked shares should not decrease once profit unlocking has started
- interest indexes should not move backwards
- settled timestamps / latest version references should not regress
- cumulative counters should only increase unless explicitly reset by design

Common mistake:
- assuming monotonicity for a value that is actually allowed to reset, decay, or be replaced by a new accounting regime

Examples from Week 8:
- Yearn: unlocked shares monotonicity
- general lesson: monotonicity invariants are often clean, durable, and high-signal when the protocol explicitly implements linear release or cumulative accrual logic

## 4. Domain separation

Question:
What accounting domains should not contaminate each other?

Typical use:
- fee routing
- reward accounting
- guaranteed vs ordinary execution paths
- liquidator / solver / referrer accounting

What to look for:
- one fee domain should not leak into another
- ordinary and guaranteed paths should remain distinct where the design says they should
- liquidator rewards, solver fees, protocol fees, and user-facing trade fees should remain separately explainable

Common mistake:
- collapsing all “fees” into one conceptual bucket and missing that the protocol intentionally routes several different fee streams differently

Examples from Week 8:
- Perennial: guaranteed intent decomposition into price override, trade fee, and claimables
- Perennial lesson: complex protocols often remain coherent only if fee domains stay separated all the way from accumulator write to user-visible outcome

## 5. Decomposability

Question:
What result should be explainable as a sum of known components?

Typical use:
- settlement systems
- fee accounting
- pnl realization
- collateral change analysis

What to look for:
- observed local/account-level delta should equal the sum of explicit components
- checkpoint / version fields should reconcile to the user-visible result
- no unexplained residual should remain after known fees, transfers, pnl, overrides, or claimables are accounted for

Common mistake:
- decomposing a result using an incomplete component set, then mistaking the missing term for a bug

Examples from Week 8:
- Perennial: plain taker checkpoint reconciles to local collateral delta
- Perennial: guaranteed intent checkpoint decomposes into price override, ordinary trade fee, and claimables

Design lesson:
Decomposition tests are often better expressed as targeted postconditions than as large generic invariants.

## 6. Global/local reconciliation

Question:
Where can global and local accounting drift?

Typical use:
- protocols with both market-level and account-level bookkeeping
- systems with aggregate pending state and per-user realized state
- fee accumulators and checkpoints

What to look for:
- global accumulator writes should reconcile to local realization
- aggregate state and per-account state should evolve on the same intended basis
- pending state should not be realized differently at global and local levels without an explicit design reason

Common mistake:
- focusing only on a local user outcome without checking whether the corresponding global accounting moved compatibly
- or focusing only on global totals and missing per-user drift

Examples from Week 8:
- Morpho: market-level totals provide a first coarse consistency check
- Perennial: local collateral delta reconciliation depends on version/checkpoint/global-local handshake
- general lesson: many serious DeFi bugs are not “bad formulas” but mismatched accounting basis across layers

## 7. Characterization vs invariant

Question:
Which properties are true protocol invariants, and which are only descriptive tests?

Definitions:
- **Characterization test**: describes how the protocol behaves under a specific scenario; useful for understanding semantics, not necessarily asserting a universal law
- **Postcondition / reconciliation test**: checks a precise relation after a specific action or path
- **True invariant**: should remain true across arbitrary valid state transitions in the tested state machine

How to decide:
A property is more likely to be a true invariant if:
- it should hold across many arbitrary sequences
- it does not depend on one special scenario
- it expresses a durable safety/accounting boundary

A property is more likely to be characterization if:
- it explains surprising but intended behavior
- it is heavily path-dependent
- it is mainly about interpreting user-visible economics rather than forbidding protocol states

Examples from Week 8:
- Morpho `some_actions_succeed` is a harness sanity check, not a true invariant
- Yearn report timing changing user outcomes is characterization, not evidence of broken accounting
- Perennial local delta decomposition is best framed as a targeted postcondition / reconciliation test
- Morpho liquidation precondition checks are closer to true invariants

Main lesson:
A large part of good invariant engineering is not writing more invariants, but correctly deciding what should **not** be written as an invariant.