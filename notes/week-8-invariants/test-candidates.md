# Test Candidates

## Yearn V3

### Candidate 1
- Hypothesis: unlocked shares should not create unexplained user claim inflation
- Priority: medium
- Type: invariant / reconciliation
- Implementation: targeted multi-user fuzz
- Why it matters: tests whether profit unlock accounting remains bounded and explainable
- Rough test shape: multi-user deposit/report/warp/redeem sequence with claim comparison

### Candidate 2
- Hypothesis: donation and report timing change user-visible economics, but should not violate total claim consistency
- Priority: medium
- Type: characterization
- Implementation: targeted test
- Why it matters: distinguishes unusual semantics from actual accounting failure
- Rough test shape: compare user outcomes before/after donation and report transitions

## Morpho Blue

### Candidate 3
- Hypothesis: healthy position cannot be liquidated
- Priority: high
- Type: true invariant
- Implementation: handler-based invariant
- Why it matters: core solvency invariant
- Rough test shape: bounded supply/borrow/repay/collateral actions plus liquidation attempts

### Candidate 4
- Hypothesis: successful borrow-side transitions should preserve recorded liquidity bounds
- Priority: high
- Type: true invariant
- Implementation: handler-based invariant
- Why it matters: prevents protocol-level inconsistency between supply and borrow accounting
- Rough test shape: handler-based sequences with borrow/repay/withdraw/supply plus liquidity assertions

## Perennial V2

### Candidate 5
- Hypothesis: local collateral delta should be decomposable into known settlement components
- Priority: high
- Type: postcondition / reconciliation invariant
- Implementation: targeted fuzz
- Why it matters: tests whether settlement accounting has unattributed residual
- Rough test shape: execute targeted update/settle path and compare local delta vs decomposed components

### Candidate 6
- Hypothesis: guarantee and ordinary fee domains should remain separated
- Priority: high
- Type: invariant / targeted fuzz
- Implementation: targeted fuzz
- Why it matters: prevents accounting contamination between fee domains
- Rough test shape: mixed guaranteed and ordinary flows across same unsettled interval