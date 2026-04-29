# Balancer V2 Issue Candidates

This document records issue candidates and high-value review surfaces identified during the Balancer V2 review pass.

Status legend:

- `open`: needs deeper review or stronger PoC
- `characterized`: tested as an intended or bounded behavior
- `not an issue`: behavior appears protected or expected under current assumptions
- `out of scope / assumption-boundary`: requires unsupported token, trusted-role violation, or unsafe external integration assumptions

This review did not identify a confirmed exploitable vulnerability. The candidates below are retained as audit-relevant surfaces, test anchors, or future bounty/contest follow-up targets.

---

## IC-01: `batchSwap` net settlement and multihop sentinel misuse

Status: `characterized`  
Potential severity if broken: `High`  
Current conclusion: `No issue observed in reviewed paths`

### Summary

`batchSwap` is one of Balancer V2's highest-value surfaces because it executes multiple pool swaps, accumulates signed asset deltas, and only settles the final net result against `funds.sender` and `funds.recipient`.

The primary concern is whether malformed multihop routes, asset-index confusion, or signed-delta mistakes could create free value, bypass limits, or cause incorrect settlement.

### Relevant code surface

- `pkg/vault/contracts/Swaps.sol`
- `batchSwap`
- `_swapWithPools`
- `_swapWithPool`

### Risk model

Each swap step should update the final net deltas as follows:

- `assetDeltas[assetInIndex] += amountIn`
- `assetDeltas[assetOutIndex] -= amountOut`

Final interpretation:

- `assetDeltas[i] > 0`: Vault receives asset `i` from `funds.sender`
- `assetDeltas[i] < 0`: Vault sends asset `i` to `funds.recipient`

`amount == 0` in a `BatchSwapStep` is not a zero-sized swap. It is a multihop sentinel that uses the previous step's calculated amount. The current step's given token must equal the previous step's calculated token.

### What would make this a real issue

This would become a real issue if any of the following were possible:

- a middle asset does not net to zero in a valid multihop route but is not settled correctly
- an `amount == 0` step can consume a previous amount for the wrong token
- asset indexes can be mismatched such that the Vault settles a different token than the pool actually swapped
- `assetDeltas` signs are interpreted inconsistently between route execution and final settlement
- user `limits` protect only local step amounts but not final net settlement

### Test evidence

The review tests cover:

- valid `GIVEN_IN` multihop net settlement
- middle asset netting to zero
- user and Vault balance deltas matching returned `assetDeltas`
- malformed multihop sentinel rejection when the next given token does not match the previous calculated token

Relevant test file:

- `BalancerBatchSwapReview.t.sol`

### Current assessment

The tested `GIVEN_IN` paths preserve net settlement and reject malformed sentinel use. No exploitable inconsistency was observed.

### Follow-up

Useful future extensions:

- `GIVEN_OUT` exact-output multihop coverage
- fuzz over multiple pools, overlapping assets, and internal-balance toggles
- relayer sender/recipient separation fuzz
- route cycles to check deterministic rounding leakage

---

## IC-02: Asset Manager managed balance can represent external claims, not Vault cash

Status: `characterized`  
Potential severity if misunderstood: `High`  
Current conclusion: `No issue observed; this is an explicit trust/accounting boundary`

### Summary

Balancer V2 splits a pool-token balance into:

- `cash`: tokens actually held by the Vault
- `managed`: tokens withdrawn by the pool-token's Asset Manager
- `total = cash + managed`: the pool's economic balance

The risk is that downstream logic may treat `managed` as immediately spendable Vault liquidity, or that a trusted Asset Manager may report misleading managed balances.

### Relevant code surface

- `pkg/vault/contracts/AssetManagers.sol`
- `pkg/vault/contracts/balances/BalanceAllocation.sol`
- `pkg/vault/contracts/balances/TwoTokenPoolsBalance.sol`

### Risk model

Asset Manager operations have different accounting meanings:

- `WITHDRAW`: moves `cash -> managed`, total unchanged
- `DEPOSIT`: moves `managed -> cash`, total unchanged
- `UPDATE`: overwrites `managed`, total may change

`UPDATE` is the profit/loss reporting trust boundary. It can increase or decrease the pool's economic total without direct Vault token movement.

### What would make this a real issue

This would become a real issue if:

- swaps or exits could spend `managed` liquidity as if it were Vault `cash`
- non-manager addresses could mutate `managed`
- `UPDATE` were reachable by an unauthorized actor
- managed balances were used in a cash-only settlement path
- `cash + managed` identity broke due to packing or specialization logic
- external integrations valued BPT without recognizing that managed balances are external claims

### Test evidence

The review tests cover:

- `WITHDRAW` moves cash to managed and preserves total
- `DEPOSIT` moves managed to cash and preserves total
- `UPDATE` overwrites managed and changes total, defining the trust boundary
- non-manager attempts to mutate pool managed balance revert
- swaps cannot pull managed balance as if it were Vault cash when cash is insufficient

Relevant test file:

- `BalancerAssetManagementReview.t.sol`

### Current assessment

The tested paths preserve the intended `cash / managed / total` model. Vault settlement remains constrained by cash availability, and unauthorized manager mutation is rejected.

This is not a vulnerability under the assumption that Asset Managers are trusted for the truthfulness of externally managed balances.

### Follow-up

Useful future extensions:

- exit path under high managed / low cash conditions
- `UPDATE` profit/loss reporting effect on BPT valuation
- multi-token and two-token specialization packing tests
- external integrator mock that incorrectly treats managed as liquid collateral

---

## IC-03: Read-only reentrancy and unsafe derived view consumption

Status: `characterized`  
Potential severity if external integration misuses views: `Medium` to `High`  
Current conclusion: `Guard behavior works in tested paths`

### Summary

Balancer V2 has historically sensitive read-only reentrancy and mixed-state risks. Pool-side derived views such as supply, rate, or invariant may be unsafe if called during an active Vault context, because Vault balances and pool-side state may be temporarily inconsistent.

Balancer provides `VaultReentrancyLib.ensureNotInVaultContext` as a guardrail for sensitive views.

### Relevant code surface

- `pkg/pool-utils/contracts/lib/VaultReentrancyLib.sol`
- `pkg/pool-weighted/contracts/WeightedPool.sol`
- `getActualSupply`
- pool-side rate / invariant / supply views

### Risk model

A derived view is unsafe if it depends on multiple state domains that may not be synchronized during a Vault operation.

Sensitive domains include:

- Vault pool balances
- BPT total supply
- pending protocol fee BPT
- invariant calculations
- rate provider state
- pool hook execution context

### What would make this a real issue

This would become a real issue if:

- an external protocol can consume a Balancer derived view during join/exit/swap mixed state
- a sensitive pool-side view lacks `ensureNotInVaultContext`
- a downstream lending or oracle protocol treats a transient rate/supply/invariant as final
- a flash loan or callback path can force an unsafe read and use it for collateral, minting, liquidation, or redemption

### Test evidence

The review tests cover:

- protected view is callable outside Vault context
- protected view reverts when invoked during join context
- protected view reverts when invoked during swap context
- protected view reverts when invoked during exit context

Relevant test file:

- `BalancerReadOnlySafetyReview.t.sol`

### Current assessment

The tested guard behavior works as expected. The reviewed path supports the model that sensitive derived views should be protected against active Vault context.

No direct Balancer-side exploit was identified.

### Follow-up

Useful future extensions:

- external oracle-consumer mock that reads unsafe views during Vault context
- compare protected vs unprotected view behavior
- concrete `getActualSupply` / `getRate` integration scenario
- composable stable pool effective-supply read during join/exit

---

## IC-04: BPT supply must distinguish raw `totalSupply()` from effective supply

Status: `open / partially characterized`  
Potential severity if broken: `Medium` to `High`  
Current conclusion: `Clean no-fee-debt paths behave as expected; pending protocol-fee debt not fully modeled`

### Summary

Balancer pools may owe protocol fees in the form of unminted BPT. As a result, raw ERC20 `totalSupply()` may differ from effective supply once pending protocol fee BPT is included.

Using raw `totalSupply()` where actual/effective supply is required can misprice BPT, dilute LPs incorrectly, or mis-measure pool ownership.

### Relevant code surface

- `pkg/pool-weighted/contracts/WeightedPool.sol`
- `getActualSupply`
- `_beforeJoinExit`
- `_afterJoinExit`
- `pkg/pool-utils/contracts/BalancerPoolToken.sol`
- `_mintPoolTokens`
- `_burnPoolTokens`

### Risk model

Important distinction:

- `totalSupply()`: currently minted BPT
- `getActualSupply()`: `totalSupply + pending protocol fee BPT`

Protocol fee BPT may be minted immediately before join/exit operations. User BPT math should account for this effective supply base.

### What would make this a real issue

This would become a real issue if:

- join/exit math uses raw supply while protocol fee debt exists
- protocol fee debt is minted after user BPT math when it should have been included before
- external integrations use raw `totalSupply()` for valuation where actual supply is required
- pending protocol fee BPT can be charged twice or missed
- `getActualSupply()` is consumed during unsafe Vault context

### Test evidence

The review tests cover clean states without pending protocol fee debt:

- fresh weighted pool has `getActualSupply() == totalSupply()`
- proportional join mints BPT and keeps actual supply aligned with raw supply in no-fee-debt state
- exit burns BPT and reduces Vault balances conservatively

Relevant test file:

- `BalancerBptReview.t.sol`

### Current assessment

The clean BPT mint/burn paths behave as expected in the reviewed tests. The more complex pending-protocol-fee-debt case remains a valuable future target.

No issue is confirmed.

### Follow-up

Useful future extensions:

- construct pending protocol fee BPT state
- assert `getActualSupply() > totalSupply()`
- join/exit before and after fee realization
- verify protocol fee BPT is minted exactly once
- compare external BPT valuation using raw vs actual supply

---

## IC-05: Protocol fee realization timing may create wrong dilution base if misordered

Status: `open`  
Potential severity if broken: `Medium`  
Current conclusion: `No issue confirmed; retained as high-value review surface`

### Summary

Weighted pools settle protocol fee debt before and after join/exit. This two-stage design prevents historical fee debt from contaminating user join/exit math and ensures this operation's fee effect is realized against the correct state.

### Relevant code surface

- `pkg/pool-weighted/contracts/WeightedPool.sol`
- `_beforeJoinExit`
- `_afterJoinExit`
- `_beforeProtocolFeeCacheUpdate`
- `_onDisableRecoveryMode`

### Risk model

Fee accounting has cut-off boundaries:

- before join/exit: settle historical protocol fee debt
- after join/exit: settle fee effects attributable to the current operation
- before protocol fee cache update: settle old-fee debt under old fee percentages
- recovery mode disable: reset stale fee debt baselines

### What would make this a real issue

This would become a real issue if:

- protocol fees can be charged twice for the same invariant/rate growth
- protocol fees can be skipped by sequencing join/exit around fee realization
- new protocol fee percentages retroactively affect historical fees
- recovery mode leaves stale fee debt that blocks or distorts later exits
- protocol fee BPT is minted against the wrong supply base

### Test evidence

Current review tests indirectly cover clean BPT join/exit behavior but do not deeply model pending protocol fee debt or fee cache update boundaries.

### Current assessment

No confirmed issue. This remains a priority candidate for deeper targeted tests if time permits.

### Follow-up

Useful future extensions:

- yield fee single-charge tests
- fee cache update before/after invariant growth
- recovery mode disable after accrued fees
- join/exit timing around pending protocol fee BPT

---

## IC-06: Non-standard token behavior at Vault settlement boundary

Status: `assumption-boundary`  
Potential severity if supported: `Medium` to `High`  
Current conclusion: `Do not escalate unless token behavior is supported by scope`

### Summary

Vault settlement assumes token transfers and balance changes behave according to supported token semantics. Fee-on-transfer, rebasing, callback-heavy, or otherwise non-standard tokens can break simple amount-based accounting if accepted without safeguards.

### Relevant code surface

- `pkg/vault/contracts/PoolBalances.sol`
- `pkg/vault/contracts/Swaps.sol`
- `pkg/vault/contracts/FlashLoans.sol`
- token transfer / balanceOf settlement boundaries

### Risk model

Non-standard token behavior may affect:

- amount received vs amount requested
- post-transfer Vault balance
- flash-loan repayment checks
- internal balance accounting
- callback sequencing

### What would make this a real issue

This becomes a real issue only if:

- the token behavior is explicitly supported, or
- the code/documentation claims compatibility, or
- the protocol permits registration of such tokens under assumptions that create loss for LPs or users.

Otherwise, it is likely an unsupported-token assumption rather than a valid vulnerability.

### Test evidence

Current review notes classify this as a support-boundary surface. It is not treated as a confirmed Balancer-native issue.

### Current assessment

No issue confirmed. Retain as an integration checklist item, not a primary vulnerability candidate.

### Follow-up

Useful future extensions:

- fee-on-transfer mock join/swap/flash-loan tests
- classify each result as unsupported-token behavior vs valid protocol failure
- document exact token support assumptions

---

## IC-07: Managed pool token mutation can pass through intentionally invalid states

Status: `open / privileged-path review surface`  
Potential severity if broken: `Medium` to `High`  
Current conclusion: `No issue confirmed; retained as privileged-control surface`

### Summary

Managed pools can add or remove tokens through privileged paths. Some transitions intentionally place the pool into a temporarily invalid state, such as registering a zero-balance token before restoring liquidity.

### Relevant code surface

- `pkg/pool-weighted/contracts/managed/ManagedPoolAddRemoveTokenLib.sol`
- `addToken`
- `removeToken`
- Vault token registration / deregistration paths

### Risk model

Privileged token mutation is safe only if:

- normal value-changing operations are blocked or safely bounded while the pool is invalid
- weight sums are repaired correctly
- token ordering remains coherent
- zero-balance deregistration is enforced
- manager actions cannot trap funds or create distorted BPT share states

### What would make this a real issue

This would become a real issue if:

- users can trade/join/exit against an intentionally invalid intermediate state
- weight rescaling creates value discontinuity
- token order or index mapping is corrupted by add/remove
- manager can trap funds by removing a token incorrectly
- BPT or pool-owned assets bypass add/remove restrictions

### Test evidence

No dedicated test was included in the current review set. This remains an explicit future target.

### Current assessment

No issue confirmed. This is a privileged transition surface and should be assessed under managed-pool trust assumptions.

---

## Summary Table

| ID | Candidate | Status | Priority |
|---|---|---|---|
| IC-01 | `batchSwap` net settlement and sentinel misuse | Characterized | P0 |
| IC-02 | Asset Manager cash/managed boundary | Characterized | P0 |
| IC-03 | Read-only reentrancy / derived view safety | Characterized | P0 |
| IC-04 | Actual supply vs raw BPT supply | Partially characterized | P1 |
| IC-05 | Protocol fee realization timing | Open | P1 |
| IC-06 | Non-standard token behavior | Assumption-boundary | P1 |
| IC-07 | Managed pool token mutation | Open | P1 |

## Overall Conclusion

No confirmed exploitable vulnerability was identified in this review pass.

The strongest reviewed surfaces were:

- `batchSwap` net settlement
- Asset Manager `cash / managed` accounting
- read-only reentrancy protection
- BPT mint/burn coherence in clean join/exit paths

The most valuable future work is deeper testing around:

- pending protocol fee BPT
- `getActualSupply() > totalSupply()` states
- `GIVEN_OUT` multihop batch swaps
- composable stable BPT-in-pool effective supply
- managed pool add/remove invalid-state transitions