# Final Review

## Protocol Summary
Panoptic V2 is an options / collateral / liquidation system layered over Uniswap-style AMM liquidity. Its security story is not just about branch correctness, but about whether premium accounting, forced actions, and liquidation settlement preserve economically coherent value transfer under stress.
The current review suggests that Panoptic’s strongest residual risk is not branch ambiguity but economically inconsistent reconciliation across premium, forced-action, and liquidation snapshots.

The review so far suggests a clear split:
- many high-level branch-selection, initialization, and binding hypotheses can be killed with offline semantic testing
- the strongest surviving concerns sit in integrated premium settlement, force-exercise, and liquidation snapshot alignment risk against live AMM state

## Scope And Method
This review phase focused on:
- manual reading of `PanopticPool`, `RiskEngine`, `CollateralTracker`, and related helpers
- review notes from `threat-model.md`, `function-notes.md`, and `invariants.md`
- targeted offline Foundry harnesses aimed at branch semantics, token semantics, factory binding, builder-wallet controls, collateral virtual shares, premium accounting, and liquidation sequencing

The current evidence base is predominantly offline / semantic. It is strong enough to kill a large number of structural hypotheses, but not yet strong enough to fully validate real value transfer across premium settlement, forced actions, and liquidation under real AMM state transitions.

## Killed Hypotheses

### 1. `dispatchFrom` branch choice is loosely steered by caller intent
This does not match the tested implementation.

Current offline tests show that `dispatchFrom` behaves as a strict shape-driven state machine:
- equal-length lists route to settle
- `toLength == finalLength + 1` routes to force exercise
- fully insolvent plus empty final list routes to liquidation
- partial solvency reverts with `NotMarginCalled`

This kills the softer hypothesis that a caller can meaningfully “label” an action as liquidation or settle independent of exact list shape.

### 2. `validateIsExercisable` is meant to encode economic moneyness
This is false in the tested implementation.

The gate is structural only: at least one long leg with nonzero width. It rejects short-only or long-loan structures, but does not encode whether the position is economically attractive to exercise at the current price.

That means future force-exercise concerns should be framed as downstream economic-settlement questions, not as a missing moneyness check in the structural gate.

### 3. Factory / tracker binding looks trivially mis-bindable or duplicate-poisonable
The current wrapper tests did not support this.

The tested deployment path:
- binds canonical token order into the trackers
- enforces single-shot initialization
- rejects duplicate market creation for the same `(poolKey, riskEngine)`
- allows distinct registry entries for distinct risk engines

This does not prove the factory surface is exhausted, but it kills the easiest registry-poisoning and token-order mismatch hypotheses.

### 4. Builder wallet controls appear trivially bypassable
The targeted tests did not support this.

The current builder-wallet surface behaved coherently under test:
- deterministic predicted address matched actual deployment
- deployment remained owner-gated
- duplicate builder code failed
- `init()` was single-shot
- `sweep()` and `execute()` remained builder-admin-only
- reasoned revert data bubbled while empty revert data mapped to `ExecuteFailed`

### 5. Virtual-share delegation is harmless bookkeeping
This is too weak a model of the system.

The tests show delegation / refund / revoke are active accounting primitives with strict sequencing assumptions. In particular, partial delegated-balance consumption can make later revoke paths fail hard instead of “healing” state.

That kills the idea that virtual anchors can be treated like soft metadata or ignored in review reasoning.

### 6. Premium accounting has a single stable notion of “premium owed”
The offline premium harness killed this simplification.

The tested view is intentionally toggle-sensitive:
- `usePremiaAsCollateral = false` excludes short-leg credit from the collateral-style aggregate
- `usePremiaAsCollateral = true` includes theoretical short-leg credit
- `includePendingPremium = false` switches the short side to `availablePremium`
- mixed long/short portfolios can materially change net premium, including sign flips, depending on those toggles

This kills the idea that a single scalar “premium owed” view is enough for review or integration reasoning.

## Surviving Concerns

### 1. Force exercise remains structurally permissive but economically unresolved
The structural gate is now characterized well, but the real question remains whether downstream cost, refund, and solvency logic make force exercise economically fair.

The strongest unresolved differential is still:
- same `tokenId`
- same oracle snapshot
- ordinary burn
- force exercise

After subtracting explicit exercise fee, these paths should not diverge in economically surprising ways unless that divergence is intentional and well-justified.

### 2. Premium settlement availability versus theoretical premium is still an integrated risk surface
Offline tests now show the intended view toggles, including multi-leg accumulation and net-premium sign flips between theoretical and available short-credit views, but they do not prove that the live system never over-credits theoretical short premium into collateral before it is economically realizable.

The unresolved part is not the existence of toggles. It is whether live settlement checkpoints remain sound across:
- chunk pokes
- partial exits
- burn/settle sequencing
- liquidation haircuts

### 3. Liquidation / forced-action snapshot alignment risk is still the main unresolved high-severity surface
The strongest remaining uncertainty is not branch selection or initialization, but integrated value transfer across premium settlement, forced actions, and liquidation under real AMM state.

Current code reading plus offline sequencing tests point to a sensitive ordering:
1. eligibility uses an available-premium-style snapshot
2. liquidation burn happens with long-premium commit intentionally deferred
3. bonus is computed from the pre-haircut view
4. haircut logic adjusts both committed premium and effective bonus
5. final collateral reconciliation happens only after those adjustments

That sequencing is coherent enough to model offline, but it remains the place where a real economic mismatch could survive despite all the branch-level tests passing.

### 4. Same insolvency premise can still fork into different outcomes under different snapshots
A major surviving concern is whether the same economic position can produce materially different liquidation outcomes because:
- eligibility snapshot
- burn settlement snapshot
- bonus snapshot
- haircut snapshot

are not perfectly aligned in a stressed live path.

The strengthened offline liquidation differential harness now supports a sharper formulation:
- same insolvency assumption
- different snapshot inputs
- different eligibility views, committed settlement amounts, and final collateral reconciliation

This is exactly the sort of issue that offline state-machine correctness will not kill by itself.

## Current Evidence

### Review Harnesses
- `PanopticBuilderWallet.t.sol`
- `PanopticCollateralVirtualShares.t.sol`
- `PanopticCoreSmoke.t.sol`
- `PanopticDispatchRouteSemantics.t.sol`
- `PanopticDispatchSemantics.t.sol`
- `PanopticFactoryBindings.t.sol`
- `PanopticLiquidationSemantics.t.sol`
- `PanopticPremiumExerciseSemantics.t.sol`
- `PanopticTokenIdSemantics.t.sol`

### Current Offline Result
- `FOUNDRY_OFFLINE=true forge test --offline --match-path 'test/Panoptic*.t.sol'`
- `98 passed, 0 failed`

## Next Review Direction
- continue deepening `PanopticPremiumExerciseSemantics.t.sol` around burn-vs-exercise differential and available-vs-theoretical premium views
- keep `PanopticLiquidationSemantics.t.sol` focused on eligibility snapshot, settlement snapshot, bonus/haircut ordering, and final collateral reconciliation
- move surviving concerns toward heavier integration or fork-capable tests once the offline semantics are saturated
- further offline effort on branch-table semantics, basic initialization, or simple structural exercisability is unlikely to produce high-value findings relative to premium/liquidation integration work
