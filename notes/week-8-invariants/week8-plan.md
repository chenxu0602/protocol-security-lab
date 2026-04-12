# Week 8 Plan

## Goal
Strengthen invariant thinking, handler design, and accounting-oriented fuzzing by reusing previously reviewed protocols instead of opening a new full review target.

## Targets
- Yearn V3 (TokenizedStrategy)
  - focus: share/accounting semantics, profit unlock, characterization vs invariant
- Morpho Blue
  - focus: solvency, liquidity bounds, liquidation, share/asset consistency
- Perennial V2
  - focus: settlement decomposition, fee-domain separation, global/local reconciliation

## Main training themes
- distinguish characterization tests from true invariants
- design bounded handlers
- use ghost variables where accounting reconciliation requires them
- express financial logic as durable invariants instead of one-off examples

## Deliverables
- 2-4 strong invariant/fuzz test suites
- invariant pattern notes
- handler design notes
- week retrospective

## Working rule
This is a testing-method week, not a full protocol-review week.