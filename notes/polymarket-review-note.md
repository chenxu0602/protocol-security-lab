# Polymarket Review Note

## Summary

I reviewed several Polymarket-adjacent wrapper, exchange, adapter, fee, and neg-risk surfaces with a mechanism-first approach: threat model, function notes, invariants, and targeted Foundry tests.

The main conclusion is not that Polymarket’s reviewed accounting paths are generically broken.

A more accurate conclusion is:

- core happy-path accounting appears coherent on the reviewed standard paths
- several meaningful defensive boundaries held under direct adversarial testing
- a small set of high-value edge risks were still confirmed with runnable local proofs

This makes the review outcome more interesting than a simple “clean” or “broken” label. The reviewed paths look directionally sound under intended assumptions, but important accounting assumptions around fee settlement, token behavior, fill fragmentation, and privileged mint authority are real and worth explicit attention.

---

## Review Focus

This review focused on local protocol surfaces exercised through:

- `ctf-exchange`
- `ctf-exchange-v2`
- `exchange-fee-module`
- `neg-risk-ctf-adapter`
- wrapper / collateral / vault components in the local Foundry harness

The key accounting question across these modules was not a single storage equality. It was whether value movement stayed coherent across:

- ERC20 collateral
- wrapped collateral supply
- ERC1155 condition-token positions
- per-fill and per-match fee paths
- vault custody
- question / condition / position identity over time

---

## What Held Under Test

Several important properties held on the reviewed paths:

- collateral wrap / unwrap behavior remained coherent on tested standard-token paths
- binary split / merge / redeem flows were conserved
- domain-separated order hashing prevented cross-instance signature replay
- partial-fill remaining moved monotonically on tested paths
- ERC1155 receive-hook reentrancy did not overfill the target order
- malformed ERC1155 batch arrays reverted rather than silently corrupting basket semantics
- unresolved CTF conditions did not release value through the reviewed adapter path
- finalized binary and multi-outcome redemptions were normalized and capped by backing
- neg-risk market growth did not rebind previously issued question / condition / position identities on tested paths

These results matter because they show that adversarial testing did not simply produce a long list of failures. Several defensive boundaries appear genuinely present.

---

## Strongest Confirmed Risks

### 1. FeeModule historical-balance over-refund

The strongest issue candidate is the FeeModule refund-boundedness failure.

The local proof showed that `FeeModule.matchOrders()` can consume historical fee inventory when `takerReceiveAmount` is inflated and refund logic is not bounded to same-transaction collected fees.

This is the highest-signal issue from the review because it is:

- concrete
- runnable
- cross-transaction in impact
- directly tied to a broken settlement-safety property

### 2. Fee-on-transfer collateral breaks exact settlement assumptions

A second strong boundary issue appears when collateral does not behave like a standard exact-transfer ERC20.

The reviewed exchange paths do not enforce exact-received semantics against taxed collateral. Under that behavior model, maker settlement can be silently underpaid even when the trade path itself completes.

This is best understood as an accounting-assumption failure rather than a cosmetic edge case.

### 3. Partial-fill fragmentation is not path-independent

A third strong issue candidate is path dependence under fragmented fills.

The local proofs showed that splitting a trade into multiple partial fills is not settlement-equivalent to a one-shot fill under certain rounding conditions. This creates a meaningful dust-fragmentation extraction path.

Again, the important point is not cosmetic rounding noise. The issue is that execution fragmentation changes the economic outcome.

### 4. Privileged mint authority is a real solvency boundary

The review also confirmed that unconditional wrapper-backing claims depend on a trust boundary around privileged mint authority.

This does **not** mean a user-reachable exploit was shown. It means solvency depends on an explicit deployment and permissions assumption that should be documented as such.

---

## Main Takeaways

### 1. “Happy path coherent” is not the same as “safe under all assumptions”

The reviewed Polymarket paths do appear largely coherent under intended standard-token and standard-flow assumptions.

But accounting systems like this are often broken not by a single obvious exploit primitive, but by hidden assumptions around:

- which execution inputs are trusted
- how fee/refund flows are bounded
- whether token transfers are exact-received
- whether fragmented execution is economically equivalent
- whether privileged supply claims are treated as invariant rather than trust-boundary dependent

### 2. Financial protocol review benefits from adversarial accounting tests

The most useful tests in this review were not generic happy-path checks.

They were adversarial tests around:

- exact-received vs assumed-received collateral
- fee sink delta vs charged fee
- refund boundedness vs stale fee inventory
- partial-fill rounding under fragmentation
- identity stability across market growth
- redemption caps under finalized payouts

This style of testing is much closer to real protocol-review work than broad surface-level smoke testing alone.

### 3. Position identity stability is as important as balance correctness

One useful lesson from neg-risk review work is that balance accounting is only one part of the problem.

When markets grow over time, the protocol also needs to preserve the meaning of existing:

- question IDs
- condition IDs
- position IDs

A system can keep balances numerically consistent while still breaking semantic identity if old positions are rebound or reinterpreted.

---

## Overall Assessment

The reviewed Polymarket wrapper, exchange, adapter, fee, and neg-risk surfaces should not be summarized as either:

- obviously broken
- or clean by default

The better conclusion is:

- core reviewed accounting paths appear coherent on intended standard paths
- several defensive boundaries survived direct adversarial testing
- multiple edge assumptions were nevertheless disproved with runnable local proofs

The review outcome is therefore a shortlist of concrete accounting and trust-boundary risks, rather than a blanket claim of protocol-wide failure.

---

## Current Priority Order

1. `FeeModule historical-balance over-refund`
2. `Partial-fill dust fragmentation extracts value`
3. `Fee-on-transfer collateral underpays maker`
4. `Direct minter unbacked supply` as trust-boundary characterization

---

## Next Review Priorities

If review work continues later, the best follow-up areas are:

- staged oracle-resolution states such as `proposed/disputable/disputed`
- full UMA dispute / oracle adapter review
- donation / preload dirty-input scenarios for wrapper / adapter / vault
- vault fee-only custody under dirty-input conditions
- production governance / deployment validation for mint authority