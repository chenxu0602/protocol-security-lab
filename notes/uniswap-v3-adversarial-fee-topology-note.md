# Uniswap V3 Adversarial Fee Topology Note

## Summary

This note records a small adversarial research pass on **Uniswap V3 core** focused on
**boundary-localized fee extraction** rather than classic correctness bugs.

The work combined:

- a Python-based **adversarial check / hypothesis generator**
- a markdown **attack workbench**
- targeted **Foundry experiments**

Main outcome:

- some feared core-pool bug classes were not supported
- several high-signal **economic extraction surfaces** were worth modeling
- two concrete adversarial scenarios were turned into passing Foundry tests

This is best understood as **economic topology research on concentrated liquidity**, not as a claim that Uniswap V3 core accounting is broken.

---

## Research setup

The workflow used a mixed Solidity + Python sandbox inside the Foundry repo:

- Foundry for executable scenario tests
- Python tooling for code-guided hypothesis generation
- markdown artifacts for review notes and attack workbenches

This ended up being a productive pattern for protocol research:

1. read core code and identify accounting / boundary surfaces
2. generate adversarial hypotheses from those surfaces
3. convert the best hypotheses into concrete Foundry experiments
4. classify results as:
   - core correctness
   - integration risk
   - economic extraction

---

## Adversarial check themes

The first pass produced a broad adversarial checklist including:

- callback reentrancy escape
- same-block oracle manipulation
- just-in-time liquidity fee sniping
- donation / balance desynchronization
- observation cardinality griefing
- dense tick gas griefing
- non-standard ERC20 attack surface
- fee accumulator wraparound

Two of these were marked as effectively handled by core semantics:

- callback reentrancy escape
- fee accumulator wraparound

Several others were more accurately framed as:

- **integration attack surfaces**
- **gas griefing surfaces**
- **economic extraction surfaces**
- **unsupported / dangerous token semantics**

That distinction matters. Not everything adversarial is a core-pool bug.

---

## Boundary fee attack workbench

A second pass focused specifically on **boundary-conditioned fee extraction**.

High-signal hypotheses included:

- boundary pinning fee capture
- cross-and-reverse tick farming
- terminal-tick JIT insertion
- liquidity cliff fee extraction
- victim range starvation
- fee-growth boundary gaming

Medium-signal hypotheses included:

- single-sided burn/collect timing
- bitmap ladder micro-region harvest

The unifying idea is that in Uniswap V3, fee realization is highly sensitive to:

- which liquidity is active at the executed path
- where price stops relative to a boundary
- how often the same initialized tick is crossed or nearly crossed
- how local liquidity topology differs from global TVL intuition

This is exactly why concentrated-liquidity systems reward **topology-aware adversarial testing**.

---

## Foundry experiments

Two hypotheses were promoted into explicit Foundry tests.

### 1. Boundary pinning

Test:

- `test_boundaryPinning_organicBoundaryFlow_narrowBandHasHigherFeePerCapital`

Scenario:

- victim provides a wide passive range
- attacker provides a narrow band near a hot boundary
- flow repeatedly touches the boundary without deeply traversing past the attacker band

What was checked:

- the wide victim should deploy more capital
- both positions should earn fees
- the attacker should achieve better **fee-per-capital efficiency**

Result:

- the scenario passed
- the narrow boundary-localized band achieved better fee efficiency than the wider passive position

Interpretation:

This does **not** show a broken fee accounting rule.
It shows that under localized boundary flow, concentrated liquidity can dominate fee capture
relative to wider passive liquidity.

That is a **real economic surface**, and it matters for:

- LP vault design
- passive liquidity assumptions
- wrapper strategies that model LP return as if fee share were approximately TVL-proportional

### 2. Cross-and-reverse farming

Test:

- `test_crossReverseFarming_selfFundedRoundTrip_isNetNegative`

Scenario:

- attacker places adjacent narrow positions around a hot boundary
- victim provides wider liquidity
- attacker self-funds a round-trip crossing cycle: cross the boundary, then reverse back

What was checked:

- the attacker should recover some LP fees
- the victim should also collect fees from attacker-funded flow
- the attacker’s total nominal balance after the cycle should be lower than before

Result:

- the scenario passed
- the attacker did recover some LP fees
- the victim also captured fees
- the attacker’s self-funded crossing cycle was **net negative**

Interpretation:

This is important because it rejects a simplistic story that “repeated crossing equals free fee farming.”

A topology-aware adversary may still extract value in more realistic flow settings,
but **self-funded oscillation alone is not automatically profitable** once other active LPs share the fee flow.

---

## What this means

### 1. Uniswap V3 core accounting still looks coherent in these paths

Nothing here established a direct core bug in:

- feeGrowthInside reconstruction
- crossing directionality
- callback settlement protection
- accumulator wraparound handling

That is consistent with the broader Week 9 review direction:
many classic concentrated-liquidity fears weaken once tested concretely.

### 2. Economic adversarial surfaces are still very real

The important lesson is not “V3 is safe, end of story.”
It is:

**V3 core can be accounting-correct while still exposing powerful fee-topology extraction surfaces.**

Those surfaces are especially relevant for:

- passive LPs
- LP vaults
- auto-rebalancers
- routers
- lending / liquidation systems using V3 liquidity assumptions
- any protocol that assumes fee outcomes track passive capital share

### 3. Boundary locality matters more than many abstractions admit

A recurring theme across the workbench is that local state dominates:

- one tick above vs one tick below a boundary
- a narrow band at the hot edge of flow
- a liquidity cliff just beyond current price
- repeated near-crossing rather than deep trend traversal

In other words, **execution topology matters**.

---

## Classification framework

A useful review pattern emerged from this work.

### Core correctness

Questions like:

- can balances be stolen?
- can accounting drift?
- can fee growth be reconstructed incorrectly?
- can callbacks escape settlement or lock assumptions?

### Integration risk

Questions like:

- can short-window TWAP consumers be manipulated?
- do wrappers infer too much from raw pool balances?
- do external systems assume only pool code changes pool balances?
- do downstream protocols trust V3 semantics too naively?

### Economic extraction

Questions like:

- can narrow liquidity dominate fee share under localized flow?
- can boundary dwell amplify fee-per-capital extraction?
- can liquidity topology create cliffs or starvation effects?
- can a sophisticated LP strategy systematically dilute slower passive LPs?

This classification is useful because it keeps research honest:
not every adversarial observation is a bug,
but many are still valuable.

---

## Why this workflow was useful

The strongest practical takeaway is methodological.

Instead of stopping at code reading, the process became:

- read code
- generate adversarial hypotheses
- write experiments
- let the mechanism falsify or support the idea

This seems especially effective for protocols where the hardest questions are about:

- path dependence
- boundary conditions
- local topology
- fee attribution
- inventory realization
- adversarial market microstructure

That description fits concentrated-liquidity systems very well.

---

## Next steps

The most natural follow-ups are:

1. extend the workbench into additional tests for:
   - liquidity cliffs
   - victim range starvation
   - fee-growth boundary gaming

2. move from local test scenarios to fork-based experiments on:
   - realistic liquidity topologies
   - realistic swap sizes
   - router behavior under dense local boundaries

3. reuse the same workflow on other protocols:
   - Aave V3 for health-factor / liquidation boundary work
   - Balancer for vault-global vs pool-local accounting
   - Panoptic or other V3-derived systems for boundary-dependent derivatives logic

---

## Closing view

Uniswap V3 still feels almost holographic:

- store the boundaries
- maintain the accumulators
- recover the interior from crossings plus accounting

The adversarial extension of that idea is:

- shape the boundaries
- localize the flow
- test who really earns the fees

That is where concentrated-liquidity research becomes interesting.
