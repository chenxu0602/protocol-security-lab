# Issue Candidates

## Status Legend
- `Review candidate`: potentially surprising, unfair, or abusable behavior that needs targeted validation
- `Expected behavior / characterization risk`: appears consistent with current design, but important enough to document because users or integrators may misunderstand it
- `Not an issue`: useful negative result or killed hypothesis

## Potential global/local mismatch

### Candidate 1: Funding, interest, or ordinary price PnL may mix socialized and raw size inconsistently
- Status: `Review candidate`
- Finding shape: Accounting mismatch / unfair value transfer
- Hypothesis:
  One or more of:
  - funding
  - interest
  - ordinary price PnL
  may use socialized size at the global write stage but raw size, or a different derived size, at the local realization stage, or vice versa.
- Why it could matter:
  Socialization is core financial semantics in Perennial. A raw-vs-socialized mismatch would likely create direct unfair transfer in exactly the stressed states where maker backing is insufficient and users are most sensitive to settlement fairness.
- Minimal scenario to test:
  Build a socialized market state where:
  - `maker + short < long`, or
  - `maker + long < short`
  Then compare:
  - expected socialized long/short PnL
  - funding notional
  - interest notional
  against the actual local realized collateral results.
- Evidence that would confirm:
  A user is settled on raw directional size where the protocol design intends socialized size, or vice versa.
- Evidence that would kill:
  In stressed socialized states, all realized value components track the intended socialized or utilized basis exactly.

### Candidate 2: Global/local mismatch on ordinary value accumulators
- Status: `Review candidate`
- Finding shape: Accounting mismatch / unfair value transfer
- Hypothesis:
  Ordinary value accumulators:
  - price PnL
  - funding
  - interest
  may be written globally on one basis or interval boundary and realized locally on another, causing account collateral deltas to diverge from the intended share of global value movement.
- Why it could matter:
  This is the main global ↔ local fairness boundary. If the `VersionLib` value delta and `CheckpointLib` realization disagree, users can be overpaid or underpaid without any obvious single-function arithmetic bug.
- Scope note:
  This candidate assumes the intended socialized/utilized basis is already correctly identified and focuses only on whether that same basis is preserved across the global-to-local handshake.
- Minimal scenario to test:
  Run a one-maker / one-long / one-short market across exactly one oracle interval with:
  - nonzero price move
  - nonzero funding
  - nonzero interest
  but zero adiabatic exposure
  Then compare the sum of local realized maker/long/short value deltas against the intended global value decomposition.
- Evidence that would confirm:
  The net realized maker/long/short collateral deltas do not reconcile exactly to the corresponding global value accumulator changes for that interval.
- Evidence that would kill:
  For a controlled one-interval scenario, local value realization matches the intended global decomposition exactly, including signs and interval boundaries.

### Candidate 3: Global/local mismatch on adiabatic exposure realization
- Status: `Review candidate`
- Finding shape: Accounting mismatch / unfair value transfer
- Hypothesis:
  Adiabatic exposure may be accumulated globally as skew-state price sensitivity but realized locally on the wrong side, wrong amount, or wrong bucket:
  - maker value when makers exist
  - global exposure when makers do not
- Why it could matter:
  Adiabatic exposure is semantically different from ordinary value accumulators. If it is wrong, the protocol may still look coherent on ordinary PnL/funding/interest tests while leaking value through the skew-state path.
- Minimal scenario to test:
  Create a market with:
  - nonzero skew
  - nonzero adiabatic fee parameter
  - one version step with no new trade but a real price move
  Compare:
  - expected `adiabaticExposure`
  - expected maker/global bucket destination
  against actual local/global realization.
- Evidence that would confirm:
  Adiabatic exposure is:
  - realized into the wrong side
  - realized with the wrong sign
  - or realized locally when it should remain market-level exposure, or vice versa
- Evidence that would kill:
  Across maker-present and maker-absent cases, adiabatic exposure always lands in the intended bucket with the intended sign and amount.

### Candidate 4: Global/local mismatch on base fee accumulators
- Status: `Review candidate`
- Finding shape: Fee overcharge / fee undercharge / unfair transfer
- Hypothesis:
  `makerFee` and `takerFee` may be normalized globally with one traded-size denominator and realized locally with another, causing accounts to pay too much, too little, or on the wrong side of the trade.
- Why it could matter:
  Base trade fee is one of the simplest economic components. If even this accumulator handshake is wrong, higher-layer settlement confidence drops sharply.
- Minimal scenario to test:
  Isolate base trade fee with:
  - no offsets
  - no funding
  - no interest
  - no guarantee
  Then compare realized maker/taker fee locally against intended global fee-index movement.
- Evidence that would confirm:
  A local account realizes more or less than the intended base fee amount for the same traded size, without a design reason.
- Evidence that would kill:
  Base maker/taker fee reconciles exactly between global accumulation and local checkpoint realization.

### Candidate 5: Global/local mismatch on offset accumulators
- Status: `Review candidate`
- Finding shape: Fee overcharge / unfair value transfer
- Hypothesis:
  `makerOffset`, `takerPosOffset`, and `takerNegOffset` may be written globally and realized locally on inconsistent side-specific traded-size bases, causing offset undercharge, overcharge, or wrong-side settlement.
- Why it could matter:
  Offsets are distinct from ordinary trade fees and already more complex because they combine:
  - linear fee
  - proportional fee
  - adiabatic fee
  A mismatch here is easy to miss if only total collateral deltas are inspected.
- Minimal scenario to test:
  Isolate offsets with:
  - zero base trade fee
  - zero funding
  - zero interest
  and compare realized local offset against intended global offset accumulator movement for:
  - takerPos-only
  - takerNeg-only
  - maker+taker mixed flow
- Evidence that would confirm:
  Local offset changes when the same intended economic trade is decomposed differently, without a design reason.
- Evidence that would kill:
  Offset realization matches the intended side-specific traded-size basis exactly across decomposition variants.

### Candidate 6: Global/local mismatch on per-order accumulators
- Status: `Review candidate`
- Finding shape: Fee overcharge / fee undercharge
- Hypothesis:
  Per-order accumulators:
  - `settlementFee`
  - `liquidationFee`
  may be written globally on one count basis and realized locally on another, causing account-level overcharge, undercharge, or repeated charging.
- Why it could matter:
  These accumulators live in a different unit domain from price/notional-based fees. If they are wrong, users can be charged even when position-size-based accounting looks correct.
- Minimal scenario to test:
  Isolate each per-order fee family separately:
  - settlement fee only
  - liquidation/protection fee only
  Then compare local realized fee against the intended global per-order accumulator semantics.
- Evidence that would confirm:
  A local account realizes:
  - more than the intended per-order fee
  - less than the intended per-order fee
  - or repeated charging where only one discrete charge was intended
- Evidence that would kill:
  Each isolated per-order fee family reconciles exactly between global accumulation and local checkpoint realization.

---

## Potential guarantee accounting mismatch

### Candidate 7: Guaranteed quantity may be mis-excluded from ordinary settlement-fee and taker-fee domains
- Status: `Review candidate`
- Finding shape: Fee undercharge / fee overcharge / unfair transfer
- Hypothesis:
  When guaranteed and non-guaranteed taker flow coexist in the same pending interval, `Guarantee.orders` and `Guarantee.takerFee` may not remain economically aligned with the intended exempt quantities, causing the guaranteed portion to either:
  - escape a fee it should still bear, or
  - get charged through both ordinary and guarantee-adjusted paths
- Why it could matter:
  This can mis-settle users through:
  - incorrect settlement fee
  - incorrect ordinary taker fee
  - incorrect decomposition between guarantee-specific and ordinary fee domains
- Minimal scenario to test:
  Queue in the same interval:
  - one direct market taker order
  - one guaranteed intent/fill taker order
  Then settle them together and compare realized settlement fee and taker fee decomposition against offchain expectations.
- Evidence that would confirm:
  The guaranteed portion is:
  - still charged ordinary settlement fee on exempt order count
  - still charged ordinary taker fee on exempt quantity
  - or exempted more broadly than intended
- Evidence that would kill:
  The realized result matches exactly:
  - no ordinary settlement fee on guaranteed order count
  - no ordinary taker fee on exempt guaranteed quantity
  - no accidental exemption leakage into non-guaranteed flow

### Candidate 8: Guaranteed price override may use the wrong signed quantity after aggregation, invalidation, or mixed pending state
- Status: `Review candidate`
- Finding shape: Accounting mismatch / unfair value transfer
- Hypothesis:
  `priceAdjustment(...)` may not remain aligned with the intended guaranteed signed taker quantity once guarantees are aggregated or partially invalidated, causing the trader to receive too much or too little guaranteed-price correction.
- Why it could matter:
  Price override is a direct value transfer:
  - `signed taker size × (oracle settlement price - guaranteed price)`
  If the signed quantity basis is wrong, settlement can favor either side materially.
- Minimal scenario to test:
  Build a mixed pending interval where:
  - one guaranteed taker order is partially invalidated or offset by later flow
  - one non-guaranteed taker order exists in the same local/global interval
  Then compare local `priceOverride` against the intended signed guaranteed quantity.
- Evidence that would confirm:
  The realized `priceOverride` does not match:
  - guaranteed signed taker size
  - multiplied by `(oracle settlement price - guaranteed price)`
- Evidence that would kill:
  Across aggregation and invalidation paths, the final `priceOverride` always matches the intended guaranteed signed taker quantity exactly.

---

## Potential protected-order fee mischarge

### Candidate 9: Protected-order fee may be charged more than once or remain live longer than intended
- Status: `Review candidate`
- Finding shape: Fee overcharge / unfair transfer
- Hypothesis:
  The protected-order liquidation/protection fee path may survive aggregation, rollover, or delayed settlement in a way that causes repeated charging or charging after the economic condition that justified the protection fee has already ended.
- Why it could matter:
  This is a discrete per-protected-order charge, not a running position-value delta. If it persists or repeats incorrectly, users can be charged multiple times for one protected-order condition.
- Minimal scenario to test:
  Create a protected order, then:
  - aggregate it with subsequent updates
  - delay settlement across multiple oracle steps
  - invalidate or otherwise resolve part of the flow
  Compare liquidation/protection fee realization count against the intended one-time protected-order charge.
- Evidence that would confirm:
  A protected-order fee is realized:
  - more than once
  - after the protected order should no longer be active
  - or on a non-protected path
- Evidence that would kill:
  Each protected-order fee is realized once, on the intended path only, regardless of aggregation or delayed settlement.

### Candidate 10: Protected-order fee may appear on paths users would not reasonably understand as liquidation
- Status: `Expected behavior / characterization risk`
- Finding shape: Documentation / integration risk
- Hypothesis:
  The checkpoint liquidation/protection fee path may trigger in cases where a frontend or user would not consider the account “liquidated,” creating a mismatch between protocol semantics and user-visible semantics.
- Why it could matter:
  Even if internally intended, this can become:
  - a user fairness dispute
  - a frontend misreporting issue
  - a final-review disclosure theme
  even if it is not a smart contract bug
- Minimal scenario to test:
  Compare:
  - one clearly protected-order / liquidator-recipient path
  - one intuitively non-liquidated path
  Check whether liquidation/protection fee appears on the latter.
- Evidence that would confirm:
  The fee appears on a path that is neither:
  - an intended protected-order charge
  - nor clearly documented as such
- Evidence that would kill:
  Every liquidation/protection fee realization corresponds to an explicitly intended protected-order accounting condition and is easy to explain in user-facing semantics.

---

## Potential denominator / unit mismatch

### Candidate 11: Settlement fee may be mischarged because fee-bearing order count is not preserved across aggregation
- Status: `Review candidate`
- Finding shape: Fee overcharge / fee undercharge
- Scope note:
  This is a narrower specialization of Candidate 6 focused specifically on preservation of fee-bearing order count across aggregation.
- Hypothesis:
  `order.orders - guarantee.orders` may fail to preserve the intended fee-bearing order count once orders are aggregated, causing settlement fee to be charged on the wrong count basis.
- Why it could matter:
  Settlement fee is not notional-based. Small count mistakes can change user charges materially, especially where many tiny orders aggregate together.
- Minimal scenario to test:
  Compare two economically similar paths:
  - one split across multiple fee-bearing orders
  - one aggregated / mixed with guaranteed-exempt order count
  Then settle both and compare settlement fee outcomes.
- Evidence that would confirm:
  Equal fee-bearing order count produces unequal settlement fee, or exempt guaranteed order count still contributes to ordinary settlement fee.
- Evidence that would kill:
  Settlement fee always tracks fee-bearing order count exactly, regardless of aggregation shape.

### Candidate 12: Trade fee or offset paths may use the wrong traded-size denominator without a design reason
- Status: `Review candidate`
- Finding shape: Fee overcharge / unfair transfer
- Hypothesis:
  Base trade fee or offset paths may be normalized by the wrong traded-size quantity:
  - maker vs taker
  - taker positive vs taker negative
  - guaranteed-exempt vs fee-bearing size
  in a way that changes realized charges without a design reason.
- Why it could matter:
  Some decomposition sensitivity is intentional:
  - proportional fees are convex
  - adiabatic fees are skew-path-dependent
  The real bug surface is where realized fee changes in a way the design does not justify.
- Minimal scenario to test:
  Construct equal-intent scenarios with decomposition variants and compare:
  - base trade fee paths
  - offset paths
  while controlling for any intended convexity or skew-path effect.
- Evidence that would confirm:
  Realized fee or offset changes even though:
  - intended traded economic quantity is the same
  - and the design provides no reason for that change
- Evidence that would kill:
  Any decomposition-sensitive change in fee/offset is fully explained by intended convexity, skew-path dependence, or side-specific pricing design.

---

## Potential user-facing economic ambiguity / fairness disclosure issue

### Candidate 13: Full settlement result may be economically correct but hard for users and integrators to interpret as “PnL”
- Status: `Expected behavior / characterization risk`
- Finding shape: Disclosure / integration risk
- Hypothesis:
  A user's realized collateral delta may diverge materially from naive directional price PnL in ways that are intentional but difficult for frontends, integrators, or users to explain, especially when:
  - offsets
  - price override
  - settlement fee
  - liquidation/protection fee
  - adiabatic fee
  - adiabatic exposure
  are all active
- Why it could matter:
  This may not be a code bug, but it is a real fairness and integration surface if users think “position PnL” should equal “settlement result.”
- Minimal scenario to test:
  Take one position through a settlement interval with:
  - directional price move
  - nonzero funding
  - nonzero interest
  - nonzero trade fee
  - nonzero offset
  - optional guarantee price override
  - optional protected-order fee
  Then decompose the final collateral delta into every component.
- Evidence that would confirm:
  The protocol is internally consistent, but the final collateral result differs materially from naive price PnL and would be easy to misreport without explicit decomposition.
- Evidence that would kill:
  Either:
  - the result is already clearly and consistently decomposed in protocol-facing APIs/docs, or
  - the difference from naive PnL is economically trivial in the tested paths

## Next Candidates To Test
- Start with:
  - Candidate 1
  - Candidate 7
  - Candidate 8
- Then test:
  - Candidate 9
  - Candidate 11
  - Candidate 4
- Then use as systematic validation / reconciliation suites:
  - Candidate 2
  - Candidate 3
  - Candidate 5
  - Candidate 6
  - Candidate 12
- Keep as characterization / final-review themes:
  - Candidate 10
  - Candidate 13
