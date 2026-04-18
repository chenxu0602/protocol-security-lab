# Aave V3 Review Note

This week I reviewed core Aave V3 accounting paths with a narrower goal than “find a bug at all costs.”

The focus was to stress a few high-signal surfaces that matter for lending-protocol correctness:

- liquidation eligibility around the health-factor boundary
- repayment-path parity between underlying repay and `repayWithATokens()`
- liquidation settlement coherence across debt burn, collateral transfer, and protocol fee extraction

## Scope

The review concentrated on:

- `GenericLogic`
- `BorrowLogic`
- `LiquidationLogic`
- `ReserveLogic`
- selected `ValidationLogic` gates

The main question was not whether Aave V3 is “complicated,” but whether a few of its most sensitive accounting transitions still reconcile cleanly when pushed near meaningful boundaries.

## Main review framing

Aave V3 is interesting because correctness is not located in one place.

It is distributed across:

- reserve-level accounting
- tokenized user claims (`aToken`, variable debt, stable debt)
- `userConfig` bits
- oracle-valued account data
- cross-reserve liquidation settlement
- side-accounting such as treasury accrual and isolation debt tracking

So a useful review has to ask not only whether each local step looks plausible, but whether the combined economic equation still closes.

## What I tested

### 1. Health-factor boundary around `HF = 1`

I built a fork-based boundary test that:

- opens a real collateralized position
- computes the collateral price that places the borrower at the liquidation boundary
- moves oracle price just above and just below that threshold

Result in the reviewed path:

- `HF > 1` → liquidation reverts
- `HF < 1` → liquidation succeeds

That does not prove every liquidation edge case is safe, but it does materially weaken the simplest version of a boundary-rounding bug claim around the main liquidation gate.

### 2. Repay-path parity

I compared:

- `repay()` using fresh underlying
- `repayWithATokens()` using an existing aToken claim

The important conclusion was that these two paths should be judged by **economic equivalence**, not by identical token-flow shape.

Result in the reviewed variable-debt path:

- debt reduction was approximately equal across both paths
- reserve/token accounting stayed directionally coherent
- the settlement leg differed, but that difference was intentional:
  - underlying repay brings fresh underlying into reserve-side settlement
  - aToken repay burns an existing claim instead

That is an implementation-path difference, not by itself an accounting failure.

### 3. Liquidation settlement coherence

I also built a liquidation-settlement test to reconcile:

- debt burned
- liquidator spend
- collateral transferred
- protocol fee
- borrower residual collateral

Result in the reviewed path:

- debt reduction matched expected debt burn
- collateral seized matched oracle pricing plus liquidation bonus
- protocol fee was carved out of bonus collateral
- user collateral loss reconciled with liquidator receive amount plus treasury fee
- total seized collateral stayed within the borrower’s actual balance

This again does not close all liquidation risk, but it weakens the most direct “over-seizure / under-burn” bug hypothesis in the reviewed branch.

## Main takeaways

### Aave liquidation is best understood as a cross-reserve settlement equation

This was the most useful accounting observation from the week.

Liquidation is not a single-reserve event. It simultaneously touches:

- the debt reserve
- the collateral reserve
- borrower state
- liquidator settlement
- treasury fee state

That means inspecting only one reserve delta can miss the real question.

The right framing is whether the combined settlement equation still closes across all legs.

### `repayWithATokens()` is different operationally, not necessarily economically

This was another good example of why path differences alone are not bugs.

The two repayment paths do not need identical intermediate flows to be correct.  
What matters is whether debt reduction, reserve reconciliation, and user claims remain economically coherent.

### Isolation-mode accounting still deserves separate attention

One thing that became clearer during the review is that isolation debt accounting is not just “whatever the live debt token balance says.”

It behaves more like principal-like side-accounting with separate update semantics.

That means if there is a future issue here, it may show up in:

- repay / liquidation transitions
- debt-ceiling drift
- rounding or unit-conversion edges

rather than in an obvious direct reserve-token mismatch.

## What the current review does **not** prove

The current review should not be read as “Aave V3 accounting is fully proven correct.”

It is much narrower than that.

What it does do is reduce confidence in several immediate local bug hypotheses in the reviewed paths.

The main open surfaces I would still prioritize are:

- mixed stable-debt / variable-debt liquidation composition
- close-factor switching around `HF = 0.95e18`
- near-exhaustion collateral rounding
- `repayWithATokens(type(uint256).max)` dust-clearing behavior
- isolation-mode side-accounting coherence under repay and liquidation

## Final view

This week’s work looks less like “I found a confirmed accounting break,” and more like:

**I used targeted tests to narrow the most obvious accounting concerns and to isolate the higher-value edge surfaces that still deserve deeper review.**

That is still good review progress.

In lending protocols, eliminating weak bug stories and sharpening the remaining ones is often more valuable than producing a shallow list of speculative issues.

## Artifacts

This review produced:

- `threat-model.md`
- `function-notes.md`
- `invariants.md`
- `issue-candidates.md`
- `final-review.md`

and three targeted Foundry tests:

- `HealthFactorBoundary.t.sol`
- `RepayParity.t.sol`
- `LiquidationSettlement.t.sol`