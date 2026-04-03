# Notes on reviewing Yearn V3 Tokenized Strategy

This week I reviewed Yearn V3 `TokenizedStrategy`.

The most useful lesson was that the main review surface is not just ERC4626 arithmetic or generic “vault safety,” but the accounting boundary between:

- reported NAV
- realizable NAV
- effective supply
- report timing

`TokenizedStrategy` looks coherent under honest reporting. In a no-op honest path, the accounting layer behaves as expected, and the locked-profit machinery produces a consistent time-based evolution of effective supply.

What made the review interesting was not a simple arithmetic bug, but how strongly user outcomes depend on the strategy callback boundary.

## 1. `_harvestAndReport()` is effectively the valuation oracle

The shared accounting layer is standardized, but the concrete strategy still decides what asset value gets surfaced into `report()` through `_harvestAndReport()`.

That means Yearn V3’s core trust boundary is not just “can the strategy deploy funds safely,” but also:

- whether valuation is fresh
- whether valuation is realizable
- whether reported profit is economically mature enough to crystallize

In other words, `_harvestAndReport()` is not just an implementation detail. It is the valuation oracle for the whole accounting system.

## 2. Profit locking helps after report, not before report

One of the clearest review results was around stale reporting.

If strategy value has already increased economically, but `report()` has not yet reconciled that increase into stored accounting, a later depositor can still enter against the old price.

That means profit locking can mitigate **post-report** profit capture, but it does not solve **pre-report** stale-price entry.

This is an important distinction, because the fairness question is not only “what happens after profit is reported,” but also “who gets to enter before accounting catches up.”

## 3. Optimistic reporting can turn paper gains into real dilution

Another important result was that optimistic reporting is more dangerous than simple temporary mispricing.

If `_harvestAndReport()` overstates value, `report()` can mint more fee shares than the honest path. After later correction, users can still end up worse off than under the honest baseline.

That means incorrect valuation at report time can turn paper profit into actual fee dilution.

## 4. Report cadence is part of the economic design

A useful mental model from this review is:

**keeper timing is not just maintenance; it is allocation.**

For the same underlying PnL path, different report timing and report frequency can produce different:

- fee-share minting
- remaining locked shares
- unlock schedule
- later entrant pricing
- incumbent vs entrant value split

So in Yearn-like systems, cadence is not just an operational detail. It is part of the fairness model.

## Main takeaway

The shared `TokenizedStrategy` logic appears coherent under honest reporting.

The harder and more interesting review question is:

**how much fairness and safety depend on the honesty, freshness, and realizability of strategy-side accounting inputs.**

That is the lens I would now use first when reviewing Yearn-like vault systems:

- reported NAV vs realizable NAV
- pre-report stale pricing
- fee minting on optimistic profit
- effective supply vs raw supply
- timing as an allocation mechanism