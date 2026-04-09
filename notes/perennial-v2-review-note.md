# Perennial V2 Review Note

This week I reviewed **Perennial V2**, a synthetic derivatives protocol with a lazy-settlement design and a more complex accounting model than a standard vault or lending system.

The most important takeaway was that the core challenge is not any single formula in isolation, but whether the protocol’s **global accumulators**, **local checkpoint settlement**, and **pending order / guarantee state** all reconcile on the same intended basis.

## Core mental model

Perennial V2 can be thought of as a three-layer state machine:

- **Global / Version**
  - protocol-wide accumulator writes
- **Local / Checkpoint**
  - account-level realization of those accumulators
- **Order / Guarantee**
  - pending execution metadata that can modify fee and settlement behavior

That structure makes the main review question:

> Are values written globally on the intended basis, and then realized locally without drift, leakage, or double counting?

## What I focused on

My review centered on:

- socialized long/short value realization
- fee-domain separation
- guarantee-specific settlement behavior
- settlement-fee and per-order count semantics
- protected-order / liquidation-style fee paths
- full user-facing settlement decomposition

Rather than only checking isolated arithmetic, I tried to verify that the **global-to-local accounting handshake** remained coherent across different execution paths.

## Main conclusions

My current view is that **Perennial V2 looks more like a protocol with unusual but internally coherent settlement semantics than one with obvious core accounting breakage in the reviewed paths**.

A number of initially plausible mismatch candidates became much weaker after targeted testing.

In particular, the reviewed paths suggested that:

- guaranteed order count was excluded from ordinary settlement-fee charging as intended
- guaranteed-exempt taker quantity was excluded from ordinary taker fee as intended
- guaranteed price override reconciled consistently with signed guaranteed quantity
- ordinary long/short realization appeared to use the intended socialized basis
- funding and utilization-related accounting looked coherent in the tested paths
- per-order charging behavior preserved count semantics in the cases I tested
- full settlement results could be decomposed into explainable components without obvious unattributed residuals in key scenarios

## Important protocol clarifications

A few semantics were especially important to pin down during the review.

### Settlement fee is not just “calling settle()”

Settlement fee is not charged merely because `settle()` is invoked.

It is charged when a **pending fee-bearing order is actually processed into a settled version**, and the charging logic is tied to **order count semantics**, not just raw notional.

### Guarantee is real accounting logic, not cosmetic metadata

`Guarantee` meaningfully changes settlement behavior.

It affects:

- exempt order count for ordinary settlement fee
- exempt taker quantity for ordinary taker fee
- guaranteed-price notional and price-adjustment logic

That means guarantee handling is not just an annotation layer; it directly changes the fee and value realization path.

### Trade fee and offset are different things

A useful distinction was:

- **trade fee** = explicit maker/taker fee
- **offset** = execution-cost / price-impact style realization via offset accumulators

These should not be collapsed into the same concept when reasoning about user-facing settlement.

### “Liquidation fee” is better read as a protected-order fee path

One subtle but important insight was that a checkpoint-level `liquidationFee` does not necessarily mean a normal liquidation event in the intuitive UI sense.

In the reviewed paths, it behaved more like a **protected-order / liquidator-compensation mechanism** that is charged discretely and routed on a specific intended path.

### User-visible PnL is not naive directional PnL

A trader’s realized settlement result can differ materially from “price went up, so I made money.”

The full realized result may include:

- realized value
- guarantee price override
- trade fees
- settlement fees
- protected-order fees
- offsets
- claimable or subtractive protocol-side adjustments

That is not necessarily a bug, but it is a major characterization point for integrators and users.

## Invariants I ended up caring about most

The review converged onto a set of accounting-oriented invariants:

1. Socialized ordinary value should use the intended basis.
2. Guaranteed-exempt order count should not pay ordinary settlement fee.
3. Guaranteed-exempt taker quantity should not pay ordinary taker fee.
4. Guaranteed price override should match signed guaranteed quantity.
5. Protected-order fee should be realized exactly once on the intended path.
6. Per-order fee accumulators should preserve count semantics across aggregation.
7. Base fee accumulators should reconcile from global write to local realization.
8. Full realized settlement should be decomposable without unattributed residual.

These were more useful than generic “math looks right” checks because they tested whether the protocol’s accounting model stayed internally consistent across layers.

## Comparison with historical official audits

Reading the historical official audits alongside this review was useful because it showed both **continuity** and **evolution** in Perennial’s risk surface.

Earlier official audits found serious concrete bugs in several recurring areas:

- **oracle / settlement-path correctness**
- **vault accounting and rebalance math**
- **liquidation / margin invariants**
- **coordinator-controlled parameter abuse**
- later, **intent / guarantee / RFQ health accounting**

In the 2023 Sherlock and Zellic reports, the dominant issues were more fundamental:

- oracle request / timestamp mismatch causing invalid settlements
- invalid oracle versions causing global/local desynchronization
- liquidation invariants that could be abused
- vault inflation and leverage / redeem-path failures

That history matters because it shows that Perennial has previously had real bugs in exactly the kinds of state-transition boundaries that deserve skepticism in a lazy-settlement system.

Later reports, especially the more recent Sherlock contests, shifted toward more specialized and protocol-evolved surfaces:

- adiabatic fee and coordinator-parameter abuse
- scale / fee-curve abuse
- intent-price and guarantee / pending-health accounting
- solver / RFQ-related settlement logic

The closest analogue to this week’s review was the **Perennial V2.4** audit, which focused heavily on intent / guarantee / invariant logic and found concrete issues in pending intent health accounting and margin-check semantics.

### My interpretation of that comparison

My review does **not** imply that historical audit findings were overblown, nor that Perennial is somehow broadly “safe because tests passed.”

The comparison instead suggests something more specific:

- historically, Perennial really did have important bugs in oracle, liquidation, vault, and parameter-control surfaces
- but in the narrower accounting paths I tested this week, many intuitive “this must be mismatched” hypotheses did **not** survive targeted adversarial checks

So the current story is not:

> “Perennial has no accounting risk.”

It is closer to:

> “In the reviewed paths, the remaining risk appears narrower and more semantic than the earlier broad classes of obvious accounting breakage.”

That is an important distinction.

The strongest remaining live surfaces from my own review were:

- denominator-sensitive offset behavior
- protocol-specific adiabatic exposure interpretation
- user / integrator interpretation of full settlement results

So compared with older official audits, my main takeaway is that the protocol now looks **less obviously broken in core reviewed settlement paths**, but still **semantically dense enough that misunderstanding the accounting model remains a real risk**.

## What remains most interesting

Most early accounting mismatch candidates were weakened or killed in the reviewed paths.

The most interesting remaining live area is still:

- **denominator-sensitive offset behavior**
- especially in decomposition-sensitive paths where the traded-size basis may matter a lot

That is the area I would push hardest if continuing the review.

## Overall assessment

Perennial V2 was a good reminder that not all difficult protocols are broken; some are just **semantically dense**.

The challenge here was not merely finding arithmetic mistakes, but understanding whether a nontrivial settlement architecture remained coherent under:

- delayed realization
- socialized exposure
- guarantee-specific execution
- multiple fee domains
- user-facing settlement decomposition

My current conclusion is that the reviewed paths support internal coherence more than obvious accounting failure.

At the same time, the historical audit record is a useful caution: this protocol family has repeatedly produced real issues when complex state transitions, oracle behavior, liquidation logic, or parameterized economic surfaces were stressed.

So the most balanced conclusion is:

**Perennial V2 currently looks more like a protocol with unusual but internally coherent settlement semantics in the reviewed paths than one with obvious core accounting breakage — but it remains a system where subtle state-machine and economic-semantic mistakes are exactly where serious bugs are most likely to hide.**