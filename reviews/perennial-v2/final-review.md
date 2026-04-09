# Final Review

## Executive Summary

The current review does not support a simple claim that `Perennial V2` core accounting is broken in the reviewed paths.

Targeted tests materially weakened or killed many initially plausible hypotheses around:
- global/local value mismatch
- guarantee fee exclusion mismatch
- per-order overcharge
- basic fee-accumulator reconciliation

The strongest remaining review surfaces are:
- denominator-sensitive offset paths
- protocol-specific adiabatic exposure semantics
- user/integration interpretation of full settlement results

## Protocol Summary

`Perennial V2` core `Market` is a lazy-settlement synthetic derivatives engine whose main correctness boundary is the handshake between:
- global accumulator writes in `Global` / `Version`
- local realized settlement in `Local` / `Checkpoint`

Pending updates are carried through global and local `Order` / `Guarantee` storage, then realized lazily when settlement advances.

The main review surface is therefore not only arithmetic correctness inside one helper, but whether:
- global accumulators are written on the intended basis
- local settlement realizes the same basis without drift
- guarantee-specific accounting stays separated from ordinary fee domains
- user-visible collateral changes remain explainable as a coherent settlement result

## Review Scope and Approach

This review focused on:
- manual review of `Market.sol`, `VersionLib.sol`, `CheckpointLib.sol`, and core accounting types
- threat-model and invariant-driven analysis
- targeted Foundry review tests derived from `issue-candidates.md`

The current Foundry review suite includes 22 targeted tests across:
- `GuaranteeCharacterization.t.sol`
- `SocializationValueReconciliation.t.sol`
- `PerOrderCharges.t.sol`
- `FullDecomposition.t.sol`

These suites intentionally serve different roles:
- **Characterization**
  - explains protocol semantics that may be surprising but internally intended
- **Reconciliation**
  - validates global-to-local accounting handshakes
- **Bug-hunting**
  - tries to break a live candidate with a concrete adversarial setup

### Review Limits

This review emphasized core accounting semantics and targeted adversarial characterization, rather than exhaustive coverage of every peripheral wrapper, integration path, or non-core module.

## Candidate Ledger

Status interpretation:
- `Killed`: targeted tests strongly contradict the hypothesized failure shape in reviewed paths
- `Weakened`: current evidence materially reduces confidence in the hypothesis, but does not exhaust all variants
- `Alive`: still worth adversarial testing
- `Characterization only`: better treated as protocol semantics / disclosure / integration theme than bug hunt

| Candidate | Current evidence | Current status | Best supporting test | In final review |
| --- | --- | --- | --- | --- |
| 1. Socialized vs raw ordinary value basis | Ordinary PnL, funding, and interest all matched intended socialized/utilized basis in targeted tests | `Weakened` | `test_pnl_formula_usesSocializedLongBasis_notRawLongSize`, `test_funding_usesSocializedTakerNotionalBasis`, `test_interest_usesUtilizedNotional_notRawGrossOpenInterest` | Yes |
| 2. Global/local mismatch on ordinary value accumulators | One-interval realization tests reconciled expected local value effects for funding and interest | `Weakened` | `test_funding_usesSocializedTakerNotionalBasis`, `test_interest_usesUtilizedNotional_notRawGrossOpenInterest` | Yes |
| 3. Global/local mismatch on adiabatic exposure realization | Adiabatic exposure routed to maker value when makers existed and to market exposure when makers were absent | `Weakened` | `test_adiabaticExposure_routesToMakerWhenMakerExists_andToGlobalExposureWhenAbsent` | Yes |
| 4. Global/local mismatch on base fee accumulators | Maker and taker base-fee accumulator writes reconciled exactly to checkpoint trade fee | `Killed` | `test_plainTakerFeeAccumulatorWrite_reconcilesToCheckpointTradeFee`, `test_plainMakerFeeAccumulatorWrite_reconcilesToCheckpointTradeFee` | No |
| 5. Global/local mismatch on offset accumulators | Offset-only decomposition reconciled in an isolated taker-positive path | `Weakened` | `test_offsetOnlyCheckpoint_reconcilesToLocalCollateralDelta` | Yes (residual live surface) |
| 6. Global/local mismatch on per-order accumulators | Settlement-fee and protected-order/liquidation-fee paths behaved correctly in targeted isolated tests | `Weakened` | `test_settlementFee_splitsAcrossAggregatedOrderCount`, `test_protectedOrder_realizesLiquidationFeeOnce_andCreditsLiquidator` | Yes |
| 7. Guaranteed quantity mis-excluded from ordinary fee domains | Guaranteed settlement-fee and taker-fee exclusions stayed aligned, including same-account mixed ordinary + guaranteed flow | `Weakened` | `test_guaranteedSettlementFeeExclusion_zeroesOrdinarySettlementFee`, `test_guaranteedTakerFeeExclusion_exemptsCounterpartyButNotTrader`, `test_sameAccountMixedGuaranteedAndOrdinaryFlow_keepsFeeDomainsSeparated` | Yes |
| 8. Guaranteed price override wrong after aggregation / invalidation | Override matched signed guaranteed quantity in clean, aggregated, and invalidation paths | `Weakened` | `test_guaranteePriceOverride_matchesSignedGuaranteedQuantity`, `test_guaranteePriceOverride_aggregatesAcrossSameInterval`, `test_guaranteePriceOverride_survivesInvalidationPath` | Yes |
| 9. Protected-order fee may repeat or outlive intended event | One-time fee realization and aggregation behavior matched intended discrete protected-order semantics | `Weakened` | `test_protectedOrder_realizesLiquidationFeeOnce_andCreditsLiquidator`, `test_protectedOrders_keepFullLiquidationFeeWhileSplittingSettlementFee` | Yes |
| 10. Protected-order fee may appear on user-unintuitive paths | Remains a protocol semantics / disclosure theme rather than a confirmed bug path | `Characterization only` | `test_protectedOrder_realizesLiquidationFeeOnce_andCreditsLiquidator` | Yes |
| 11. Settlement fee count may drift under aggregation | Fee-bearing order count was preserved in tested aggregation paths | `Killed` | `test_settlementFee_splitsAcrossAggregatedOrderCount`, `test_guaranteedSettlementFeeExclusion_zeroesOrdinarySettlementFee` | No |
| 12. Wrong traded-size denominator without design reason | Not exhaustively broken; current tests support intended base-fee and some offset semantics, but decomposition-sensitive paths remain open | `Alive` | `test_plainTakerFeeAccumulatorWrite_reconcilesToCheckpointTradeFee`, `test_offsetOnlyCheckpoint_reconcilesToLocalCollateralDelta` | Yes (residual live surface) |
| 13. Full settlement result may be hard to interpret as “PnL” | Strongly supported as a product/integration characterization theme | `Characterization only` | `test_plainTakerCheckpoint_reconcilesToLocalCollateralDelta`, `test_guaranteedIntentCheckpoint_decomposesIntoPriceOverrideTradeFeeAndClaimables`, `test_guaranteedIntentCheckpoint_explicitlySplitsGrossSubtractiveSolverAndNetLocalEffect` | Yes |

## Strongest Current Conclusions

### 1. Core guarantee accounting appears internally coherent in the tested paths

The current evidence strongly supports the following:
- guaranteed order count is correctly excluded from ordinary settlement fee
- exempt guaranteed quantity is correctly excluded from the intended ordinary taker-fee domain
- guaranteed price override matches signed guaranteed quantity in:
  - clean single-order paths
  - same-interval aggregation
  - invalidation paths

This is one of the strongest review-supported areas so far.

### 2. Socialization and utilization semantics look coherent in the tested ordinary value paths

The current tests support:
- ordinary long/short PnL using socialized directional basis
- funding being sourced from socialized taker-notional basis
- interest being sourced from utilized notional rather than raw gross open interest

This does not prove every stressed or adversarial state, but it materially weakens the highest-priority raw-vs-socialized drift hypothesis.

### 3. Per-order charging semantics also look coherent in the tested paths

The current evidence supports:
- noop updates not paying ordinary settlement fee
- settlement fee splitting by fee-bearing order count across aggregation
- protected-order fee realizing once per intended event
- liquidation/protection fee staying discrete while ordinary settlement fee still splits by count

This does not prove every edge case, but it meaningfully weakens the main per-order overcharge hypotheses.

### 4. Full settlement decomposition is now explainable in several important user-facing paths

The current decomposition tests support that a user’s local collateral result can be explained by:
- transfer
- realized collateral/value
- guarantee price override
- trade fee
- settlement fee
- protected-order fee
- subtractive fee / solver carve-out claimables

This is important both for correctness review and for user-facing interpretation risk.

## Recommended Next Review Work

### 1. Continue adversarial work on Candidate 12

The current tests kill or weaken many direct fee-accounting mismatch hypotheses, but they do not fully exhaust:
- decomposition-sensitive offset paths
- more complex positive/negative taker mixes
- scenarios where a denominator bug could hide behind intended convexity or skew-path dependence

If more adversarial testing is added, this remains one of the best places to spend it.

### 2. Preserve adiabatic exposure as a separately explained economic surface

Current test support shows correct bucket destination:
- makers present -> maker value
- no makers -> market exposure

Even so, adiabatic exposure remains a protocol-specific economic surface and should be explained separately in any external writeup, because it is easy to confuse with ordinary directional PnL.

### 3. Keep Candidate 10 and Candidate 13 out of bug-hunt severity framing

The review now has enough evidence to treat these as:
- user-facing economic interpretation risk
- protocol semantics / disclosure / integration risk

They are important final-review themes, but should not be mixed with medium-severity accounting-bug candidates.

## Overall Assessment

The current review evidence does not support a simple claim that `Perennial V2` core accounting is broken.

The stronger story is:
- global-to-local accounting appears coherent across the main tested ordinary value, guarantee, and per-order fee paths
- guarantee accounting is more internally consistent than it may first appear
- many initially plausible fee-count and handshake mismatch candidates are now weakened or killed by targeted tests
- the remaining high-signal review surface is less about basic arithmetic error and more about:
  - denominator-sensitive offset paths
  - protocol-specific adiabatic economics
  - user/integration interpretation of full settlement results

In short:

`Perennial V2 currently looks more like a protocol with unusual but internally coherent settlement semantics than one with obvious core accounting breakage in the reviewed paths.`

This matters because the protocol’s main residual risk is less likely to be a trivial arithmetic bug and more likely to be a misunderstanding of specialized settlement semantics, denominator-sensitive fee behavior, or user-facing interpretation.

That is good news for arithmetic integrity, but it also means the final review should emphasize:
- economic semantics
- user-visible interpretation risk
- narrow remaining live candidates
- explicit separation between bug candidates and characterization themes