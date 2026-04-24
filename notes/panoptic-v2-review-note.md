# Panoptic V2 Review Note

Panoptic V2 is best understood as an options / collateral / liquidation system built on top of Uniswap-style AMM liquidity, not as a simple vanilla options protocol. The main review question is therefore not just whether branch routing is correct, but whether premium accounting, forced actions, and liquidation preserve economically coherent value transfer under stress. Current review evidence suggests that the strongest residual risk is not branch ambiguity, but reconciliation across premium, forced-action, and liquidation snapshots. :contentReference[oaicite:0]{index=0}

## Review Scope

This review combined:
- manual reading of `PanopticPool`, `RiskEngine`, `CollateralTracker`, and helpers
- structured notes from `threat-model.md`, `function-notes.md`, and `invariants.md`
- targeted offline Foundry harnesses for:
  - dispatch routing
  - token semantics
  - factory binding
  - builder-wallet controls
  - collateral virtual shares
  - premium-accounting views
  - liquidation sequencing

Current offline result:
- `FOUNDRY_OFFLINE=true forge test --offline --match-path 'test/Panoptic*.t.sol'`
- `98 passed, 0 failed` 

## What Was Clarified

### `dispatchFrom` is shape-driven, not intent-driven
Offline tests support that `dispatchFrom` is a strict shape-driven state machine:
- equal-length lists route to settle
- `toLength == finalLength + 1` routes to force exercise
- fully insolvent plus empty final list routes to liquidation
- partial solvency reverts with `NotMarginCalled`

This substantially weakens the hypothesis that callers can loosely steer branch type by intent alone. 

### `validateIsExercisable` is structural only
The current gate is purely structural:
- short-only positions are non-exercisable
- long `width == 0` loan/credit legs are non-exercisable
- any long leg with nonzero width is exercisable regardless of strike or moneyness

This means economic exercise fairness must come from downstream cost and settlement logic, not from the structural gate itself. 

### Premium accounting is intentionally view-sensitive
Offline premium tests show there is no single universal notion of “premium owed”:
- `usePremiaAsCollateral = false` excludes short-leg credit from collateral-style aggregate
- `usePremiaAsCollateral = true` includes theoretical short-leg credit
- `includePendingPremium = false` switches short-side treatment to `availablePremium`
- mixed long/short positions can materially change net premium, including sign, depending on toggles

This means future review must distinguish carefully between theoretical, settled, and realizable premium. 

### Virtual-share delegation is a real accounting primitive
`delegate / refund / revoke` is not harmless metadata:
- `delegate()` credits virtual shares without changing total supply
- `refund()` can consume delegated shares
- after partial economic consumption, `revoke()` can fail hard rather than “heal” state

This makes virtual-share sequencing a real accounting surface. 

## Killed Directions

Current offline semantic work substantially weakens:
- loose intent-driven branch ambiguity in `dispatchFrom`
- the idea that `validateIsExercisable` is intended as an economic moneyness gate
- trivial factory/tracker token-order misbinding in the tested wrapper path
- trivial builder-wallet auth bypass
- the idea that premium accounting has a single stable interpretation across all uses :contentReference[oaicite:6]{index=6}

## Main Surviving Concerns

### 1. Burn vs force-exercise economic consistency
The strongest unresolved differential remains:
- same `tokenId`
- same oracle snapshot
- ordinary burn
- force exercise

After subtracting explicit exercise fee, these paths should not diverge in economically surprising ways unless that divergence is intentional and justified. 

### 2. Premium settlement availability versus theoretical premium
The unresolved question is not whether premium-view toggles exist, but whether live settlement ever over-credits theoretical short premium into collateral before it is economically realizable. This still needs deeper validation around:
- `s_settledTokens`
- `availablePremium`
- checkpoint rebasing
- burn/settle sequencing
- liquidation haircut paths 

### 3. Liquidation / forced-action snapshot alignment
This remains the main unresolved high-severity surface.

Current code reading plus offline tests support a sensitive ordering:
1. eligibility uses an available-premium-style snapshot
2. liquidation burn defers long-premium commit
3. bonus is computed from the pre-haircut view
4. haircut adjusts committed premium and effective bonus
5. final collateral reconciliation happens afterward

That sequencing appears coherent offline, but it remains the most plausible place for economic mismatch to survive under live AMM state. 

### 4. Same insolvency premise, different outcomes under different snapshots
A major surviving concern is whether the same economic position can produce materially different liquidation outcomes because:
- eligibility snapshot
- burn settlement snapshot
- bonus snapshot
- haircut snapshot

are not perfectly aligned in a stressed live path. 

## Practical Takeaway

Panoptic currently looks less like a protocol with obvious branch-table or initialization bugs, and more like a system whose residual risk is concentrated in **economic reconciliation across multiple internal views of the same position**:
- theoretical vs available premium
- burn vs force exercise
- eligibility vs settlement vs haircut vs final collateral reconciliation :contentReference[oaicite:11]{index=11}

## Best Next Step

Further offline work on:
- branch-table semantics
- basic initialization
- simple structural exercisability

is unlikely to produce as much value as deeper integration or fork-capable testing around:
- burn-vs-exercise differential
- available-vs-theoretical premium handling
- liquidation snapshot alignment
- live Uniswap-linked settlement paths :contentReference[oaicite:12]{index=12}
