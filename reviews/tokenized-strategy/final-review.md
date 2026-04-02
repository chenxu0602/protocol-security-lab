# Final Review

## Protocol Summary
Yearn V3 `TokenizedStrategy` is a single-strategy vault framework in which each concrete strategy delegates ERC20, ERC4626, reporting, fee, and profit-unlock logic to a shared implementation via `delegatecall`.

The shared accounting layer is standardized, but the concrete strategy remains responsible for surfacing truthful asset value and realizable liquidity through `_harvestAndReport()` and `_freeFunds()`.

This makes the protocol’s security story less about isolated arithmetic bugs and more about accounting trust boundaries:

- entry pricing depends on stored `totalAssets`, not live balance
- effective supply depends on locked/self-held shares, not raw supply alone
- `report()` is the crystallization point for profit, loss, fees, and unlock state
- keeper/report cadence is an allocation mechanism, not merely an operational detail

## In-Scope Files

### Core Contracts
- `evm-playground/src/review/TokenizedStrategy.sol`
- `evm-playground/src/review/BaseStrategy.sol`

### Supporting Interfaces / Test Harness
- `evm-playground/src/review/interfaces/ITokenizedStrategy.sol`
- `evm-playground/src/review/interfaces/IStrategy.sol`
- `evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol`

## Scope Boundaries
This review focused on:

- accounting state transitions
- strategy callback trust boundaries
- entry and exit pricing against stored accounting
- report-time profit, loss, fee, and unlock transitions
- targeted scenario testing for stale valuation, optimistic valuation, unlock timing, and report cadence

This review did **not** attempt to provide:

- a full privilege review of all operational roles
- a full integration review of all possible concrete Yearn strategies
- a comprehensive survey of external dependency or deployment risk
- a complete exit-side analysis under all `_freeFunds()` shortfall scenarios

The strongest conclusions in this document therefore apply to Yearn-like integrations where valuation freshness and realizable liquidity can diverge from stored accounting.

## Review Approach
The review combined:

- manual reading of accounting flows and trust boundaries
- analysis of entry and exit pricing against stored accounting
- focused reasoning about `report()` as the profit/loss crystallization boundary
- targeted review tests covering honest, stale, and optimistic valuation paths
- comparison of alternate report timing and report frequency on the same economic path
- separation of expected locked-profit behavior from economically important review candidates

The current custom review test file provides evidence for the following higher-level themes:

- honest reporting keeps the shared accounting layer coherent
- stale reporting can improve entry terms for later depositors relative to fresher accounting
- optimistic reporting can over-mint fee shares and worsen downstream outcomes
- report timing and report frequency materially change allocation outcomes even on the same PnL path

## Main Attack Surfaces
- `_harvestAndReport()` as the valuation oracle for `report()`
- `_freeFunds()` as the realizable-liquidity oracle for exits
- deposits and mints against stale `totalAssets`
- report-time fee-share minting
- self-held locked shares and effective-supply decay over time
- keeper / management control over report cadence

## Core Security Properties Reviewed
- no-op honest reports should not change user claims
- profit locking should smooth post-report profit realization in a coherent way
- effective supply rather than raw supply should explain PPS evolution during unlock
- stale accounting should be understood as an entry-pricing trust boundary
- optimistic valuation should be understood as a fee-accounting and allocation trust boundary
- report timing should be understood as a user-allocation input, not just a maintenance concern

## Main Review Conclusions

### A. Pre-report stale-price entry can shift previously accrued value toward later entrants
Targeted testing showed that if real strategy value has increased but `_harvestAndReport()` has not yet reconciled that increase into stored accounting, a later depositor can still enter against the old accounting price.

Compared with a fresher-report path, the stale path allows the later entrant to receive more favorable share issuance and to participate in gains that accrued before entry under updated accounting.

Profit locking does not mitigate this specific scenario because the gain has not yet been crystallized by `report()`.

#### Why this matters
Depositor fairness depends directly on reporting cadence and valuation freshness. The accounting layer may remain internally coherent while still producing materially different cross-user outcomes before `report()` catches up to economic reality.

#### Classification
Strong trust-boundary / accounting-freshness review theme. Not, by itself, evidence of a pure shared-logic bug.

---

### B. Optimistic reporting can over-mint fee shares and leave users worse off after correction
Targeted testing showed that when `_harvestAndReport()` overstates value:

- `report()` mints more fee shares than in the honest path
- `report()` also creates more locked shares than in the honest path
- after later correction, both the incumbent depositor and the later depositor can remain worse off than in the honest comparison path

This is stronger than a transient entry-pricing distortion. It shows that report-time overvaluation can crystallize paper gains into real fee dilution.

#### Why this matters
`_harvestAndReport()` is not merely an informational callback. It is the valuation oracle for profit realization, fee extraction, and future user allocation. If the strategy reports optimistic NAV rather than realizable NAV, the system can mint economically unjustified fee shares before the accounting is corrected.

#### Classification
Strong trust-boundary / fee-accounting review theme. Most likely integration-sensitive rather than a pure base-contract bug.

---

### C. Report timing and report frequency are allocation mechanisms
Targeted testing confirmed two closely related expected-but-important behaviors:

1. Earlier reporting on the same economic path favors incumbents relative to later entrants.
2. More frequent reporting on the same PnL path changes fee-share minting, remaining locked shares, unlock schedule, and eventual user allocation.

For the same real asset path, a Day 5 + Day 10 reporting cadence and a Day 10-only reporting cadence do not produce the same Day 10 accounting state. The two-report path leaves less still locked by Day 10, shortens the remaining unlock horizon, and changes who captures value after a later deposit.

#### Why this matters
Keeper/report cadence is part of the economic design, not just operational hygiene. Users following the same underlying profit path can receive materially different outcomes depending only on when reports occur.

#### Classification
Expected behavior, but important enough to elevate as a primary design property in any Yearn-like review.

## Confirmed Expected Behaviors

### 1. Honest no-op reporting is a useful control case
Under an honest harness with no economic change, `report()` does not shift user claims or total supply. This is a valuable baseline showing that the shared accounting machinery is stable when the callback boundary behaves honestly.

### 2. Immediate post-report entrants can still share in locked value
Immediately after a profitable `report()`, but before any profit has unlocked, a new entrant can still deposit at a price that does not reflect the reported gain in the intuitive way many users might expect. This appears to be a consequence of Yearn’s locked-profit design rather than evidence of a standalone bug.

### 3. Mid-unlock entrants receive fewer shares than immediate post-report entrants
As locked profit unlocks over time, effective supply changes and later entrants receive fewer shares for the same assets. This confirms that time-based unlock meaningfully affects pricing even when stored `totalAssets` is unchanged.

## Overall Assessment
The shared `TokenizedStrategy` logic reviewed here appears internally coherent under honest reporting. The more important security story is that fairness and economic safety depend heavily on the honesty, freshness, and timing of strategy callbacks.

The main conclusions from this review are:

- the shared accounting layer appears capable of expressing the intended locked-profit model coherently
- `_harvestAndReport()` effectively acts as the valuation oracle for the system
- stale valuation can improve entry terms for later entrants relative to fresher accounting
- optimistic valuation can crystallize paper gains into fee dilution
- report cadence itself changes how value is distributed across users and fee recipients

For Yearn-like systems, the most important review lens is therefore not just arithmetic correctness, but the relationship between:

- reported NAV and realizable NAV
- pre-report stale pricing and post-report profit locking
- effective supply and raw supply
- time-based unlock and report-based reconciliation
- fee minting and paper profit recognition
- strategy callback honesty and user allocation fairness

## Remaining Gaps
The main unresolved directions from this review are:

- add `undervalue` scenarios to map the reverse transfer direction
- add repeated pre-report deposit scenarios to quantify how much value later entrants can accumulate before realization
- add protocol-fee-enabled variants to separate protocol-fee dilution from strategist-fee dilution
- add withdraw / redeem tests under `_freeFunds()` shortfall, since the exit-side trust boundary remains materially underexplored
- add scenarios where later entrants arrive between multiple reports to better characterize cadence sensitivity