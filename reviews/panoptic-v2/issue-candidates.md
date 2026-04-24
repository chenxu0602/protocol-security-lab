# Issue Candidates

## Status Legend
- `Confirmed intended behavior`: tested behavior matches the current implementation and looks deliberate, though it may still be operationally surprising
- `Characterization risk`: behavior appears real and important, but is better framed as design/accounting semantics than a straightforward bug from current evidence
- `Open candidate`: still worth deeper exploit-style or fork-based validation

## Confirmed Intended Behavior

### 1. `dispatchFrom` branch selection is driven by list shape first, not by user intent labels
- Status: `Confirmed intended behavior`
- What was checked:
  - same-length `positionIdListTo` / `positionIdListToFinal` routes to settle
  - `toLength == finalLength + 1` routes to force exercise
  - fully insolvent + `finalLength == 0` routes to liquidation
  - partial solvency reverts with `NotMarginCalled`
- Observation:
  - `dispatchFrom` is a strict shape-driven state machine.
  - In particular, a solvent account with a single valid long position and `final == []` is interpreted as force exercise, not liquidation.
  - Same-content-but-different-order lists fail settle with `InputListFail`.
- Why it matters:
  - This kills a vague review hypothesis that caller intent alone could steer the branch.
  - Remaining concerns should focus on whether the shape-based routing is economically fair, not whether the branch table is ambiguous.
- Related tests:
  - `PanopticDispatchSemantics.t.sol`

---

### 2. `validateIsExercisable` is purely structural, not economic
- Status: `Confirmed intended behavior`
- What was checked:
  - short-only position returns non-exercisable
  - long loan/credit leg (`width == 0`) returns non-exercisable
  - any long leg with nonzero width returns exercisable, regardless of strike / moneyness
- Observation:
  - The gate is exactly “has at least one long, non-loan leg”.
  - It does not check whether the position is economically ITM or fair to exercise at current price.
- Why it matters:
  - This confirms the review theme that the real protection must come from downstream exercise-cost and settlement math.
  - Any future issue candidate should be framed as “economic exercise path is too permissive despite structural gate” rather than “the structural gate forgot to check price”.
- Related tests:
  - `PanopticTokenIdSemantics.t.sol`

---

### 3. Factory binding and registry semantics are coherent in the tested V4 harness
- Status: `Confirmed intended behavior`
- What was checked:
  - deployed pool binds canonical token order into both trackers
  - pool / tracker initializers are single-shot
  - duplicate deployment for same `(poolKey, riskEngine)` reverts
  - different risk engines get distinct registry entries
  - zero risk engine reverts
- Observation:
  - No simple pool/tracker inversion or duplicate-registry bug was reproduced in the wrapper harness.
- Why it matters:
  - This reduces concern that Panoptic market creation is trivially poisonable through repeated deploys or obvious token-order mismatch.
  - Future factory review should focus on subtler clone-address / upgrade / admin mutation concerns.
- Related tests:
  - `PanopticFactoryBindings.t.sol`

---

### 4. Builder wallet deployment and admin-gated execution behave coherently
- Status: `Confirmed intended behavior`
- What was checked:
  - deterministic `predictBuilderWallet()` matches actual deployment
  - only factory owner can deploy
  - duplicate builder code fails CREATE2 deployment
  - wallet init is single-shot
  - `sweep()` and `execute()` are builder-admin-only
  - empty revert in downstream call maps to `ExecuteFailed`, reasoned revert bubbles
- Observation:
  - The builder-wallet control surface behaves consistently with the current permission model.
- Why it matters:
  - This lowers concern of a trivial wallet misbind or unauthenticated sweep/execute path.
  - Remaining review effort should focus on whether the permissions themselves are too strong, not on a basic auth bypass.
- Related tests:
  - `PanopticBuilderWallet.t.sol`

---

## Characterization Risks

### 5. `dispatch` and `dispatchFrom` both rely on rigid list-shape / hash discipline that is easy to misuse
- Status: `Characterization risk`
- Observation:
  - User/account state is validated through ordered list equality plus stored XOR-style position hash.
  - Wrong ordering, duplicate ids, wrong pool id, or shape mismatch all fail hard.
  - `dispatch` and `dispatchFrom` both route on current-state interpretation, not on an explicit enum supplied by the caller.
- Why it matters:
  - This is likely deliberate, but it creates a brittle integration surface.
  - Routers, keepers, and external liquidators must construct exact list state or revert.
  - It also means “liquidation-like” or “settle-like” intent is not enough; the exact encoded transition shape matters.
- Related invariants:
  - position supply ↔ obligations bijection
  - branch selection must not desync internal state from ERC1155 position lists
- Related tests:
  - `PanopticDispatchSemantics.t.sol`
  - `PanopticDispatchRouteSemantics.t.sol`

---

### 6. Virtual-share delegation is real protocol semantics and can fail hard after partial economic consumption
- Status: `Characterization risk`
- Observation:
  - `delegate()` credits `type(uint248).max` virtual shares without changing total supply.
  - `refund()` can consume those delegated shares.
  - After delegated balance is partially consumed, `revoke()` can revert on underflow rather than “healing” state.
- Why it matters:
  - This is not a fake or harmless bookkeeping trick. It is an active accounting primitive with strict sequencing assumptions.
  - Any path that delegates, partially consumes, and later revokes must be reasoned about very carefully.
  - This matches the review concern that virtual anchors must not be mistaken for ordinary redeemable vault claims.
- Related invariants:
  - delegate/revoke/refund should not create redeemable value from synthetic anchors
  - revoke must not assume pristine delegation state after economic consumption
- Related tests:
  - `PanopticCollateralVirtualShares.t.sol`

---

### 7. CollateralTracker’s initial virtual-share baseline heavily shapes dust and preview behavior
- Status: `Characterization risk`
- Observation:
  - The vault starts at `totalAssets = 1`, `totalSupply = 1_000_000`.
  - All preview/convert functions inherit that virtual baseline.
  - Fresh-account `maxWithdraw/maxRedeem` are zero even though conversion math itself is defined.
- Why it matters:
  - This is expected under the current anti-inflation design, but it creates non-intuitive small-value behavior.
  - Any bug candidate around withdrawals, tiny deposits, dust, or “why did preview return that number?” needs to account for this baseline first.
- Related invariants:
  - share/asset conservation under virtual-share bootstrap
  - rounding and minimum redemption behavior should remain coherent under tiny values
- Related tests:
  - `PanopticCollateralVirtualShares.t.sol`

---

### 8. `dispatch` safe-mode semantics are intentionally asymmetric and route-shaping
- Status: `Characterization risk`
- Observation:
  - `safeMode > 1` forces tick-limit ordering into a covered-style direction.
  - `safeMode > 2` blocks new mint branch with `StaleOracle`.
  - Existing positions still route through settle/burn logic rather than being globally disabled by the same top-level check.
- Why it matters:
  - Safe mode is not a single global pause. It reshapes allowed transitions differently for new vs existing exposure.
  - This is exactly the kind of behavior integrators may misunderstand if they model safe mode as a uniform freeze.
- Related invariants:
  - emergency controls should block risk-increasing actions coherently without accidentally breaking intended risk-reducing flows
- Related tests:
  - `PanopticDispatchRouteSemantics.t.sol`

---

### 9. Premium accounting view is intentionally toggle-sensitive before live settlement
- Status: `Characterization risk`
- Observation:
  - `usePremiaAsCollateral = false` excludes short-leg premium credit entirely from the collateral-style aggregate.
  - `usePremiaAsCollateral = true` includes theoretical short-leg premium in the aggregate view.
  - `includePendingPremium = false` switches the short side from theoretical/raw premium to `availablePremium` only.
  - On mixed long/short positions, the net premium view can materially change sign depending on whether pending or only available short premium is admitted.
- Why it matters:
  - This appears deliberate, but it means “premium seen by risk/collateral logic” is not identical to “premium already realizable/withdrawable now”.
  - Future findings should distinguish between documented view-switching semantics and a true over-credit / checkpoint-integrity failure.
- Related review themes:
  - premium checkpoint integrity
  - seller-claimable premium bounded by actually settled tokens
- Related tests:
  - `PanopticPremiumExerciseSemantics.t.sol`

---

### 10. Liquidation sequencing is intentionally multi-snapshot and economically ordering-sensitive
- Status: `Characterization risk`
- Observation:
  - liquidation eligibility is computed from an available-premium-style view, not from full theoretical short premium
  - liquidation burn semantics intentionally defer long-premium commit until after haircut logic is determined
  - bonus deltas are applied before final collateral reconciliation
  - final liquidatee/liquidator collateral transfer is therefore downstream of both haircut and bonus adjustment
  - under the same liquidation/insolvency assumption, changing only eligibility, bonus, or haircut snapshot inputs can still produce different intermediate or final outcomes
- Why it matters:
  - This appears coherent with the current implementation shape, but it means liquidation fairness depends on sequencing discipline across multiple snapshots rather than on a single “insolvent or not” truth.
  - Future findings should focus on whether those snapshots stay economically aligned under live AMM state transitions, not on whether the branch table itself is ambiguous.
- Related review themes:
  - liquidation / force-close edge cases and griefing resistance
  - premium haircut and settlement consistency
- Related tests:
  - `PanopticLiquidationSemantics.t.sol`

---

### 11. Several historically reported RiskEngine / OraclePack edge cases are now best treated as mitigation regressions on current code
- Status: `Confirmed intended behavior`
- What was checked:
  - `getLiquidationBonus` no longer underflows on a distribution-insolvent shape
  - multi-leg credit accumulation in `_getRequiredCollateralAtTickSinglePosition()` now aggregates instead of overwriting
  - `twapEMA` weights fast / slow / eons and ignores spot
  - width-1 long at strike no longer divides by zero
  - `rebaseOraclePack()` preserves EMAs and lock mode
  - `safeMode > 0` forces 4-tick solvency checks on the symmetric blind-spot shape
  - same-epoch `updateInterestRate()` no longer compounds `rateAtTarget`
- Observation:
  - These are exactly the kind of issues that previously made sense as vulnerability candidates, but on the current codebase they behave more like mitigation-confirmation regressions.
- Why it matters:
  - Review effort should not keep treating these as open bug suspicions in the current branch.
  - They are still worth retaining as regression coverage because several were historically high-signal C4-style findings.
- Related tests:
  - `PanopticRiskEnginePoCs.t.sol`

---

### 12. Burn-based commission distribution remains economically JIT-sensitive when fees are burned to PLPs
- Status: `Characterization risk`
- Observation:
  - `settleMint()` / `settleBurn()` with `feeRecipient == 0` burn commission shares from the option owner instead of transferring them to an explicit recipient.
  - That lowers `totalSupply` without removing assets and therefore lifts share value for whoever is in the vault at that instant.
  - A dominant entrant present at the event captures materially more uplift under the burn-to-PLPs path than under the transfer-to-builder path.
- Why it matters:
  - This does not by itself prove an exploitable production path, but it confirms the core economic mechanism behind the old “JIT-capturable commission burn” concern.
  - Future heavier review should focus on how accessible / repeatable this path is in live flows, not on whether the uplift mechanism exists.
- Related tests:
  - `PanopticSettlementPoCs.t.sol`

---

## Open Candidate Concerns

### 13. Structural exercise permissiveness still needs true economic-path validation
- Status: `Open candidate`
- Hypothesis:
  - Because `validateIsExercisable` only checks structural long-leg existence, the real safety burden sits on:
    - `exerciseCost(...)`
    - downstream settlement/refund math
    - post-exercise solvency checks
- Why it is still worth digging:
  - The current tests confirm the weak structural gate, but do not prove economic fairness.
  - A solvent account may still be exposed to an economically abusive force-exercise path if cost/reconciliation is misaligned.
- What to probe next:
  - real `dispatchFrom` force-exercise paths against structurally valid but economically unattractive positions
  - compare exercisor cost, exercisee loss, and post-action solvency under multiple ticks
- Related tests:
  - current characterization only: `PanopticTokenIdSemantics.t.sol`, `PanopticDispatchSemantics.t.sol`

---

### 14. Premium settlement availability vs theoretical premium still needs integrated proof
- Status: `Open candidate`
- Hypothesis:
  - seller-claimable premium may still diverge from truly settled/available premium in some live-flow path, especially around chunk pokes, partial exits, or liquidation haircuts
  - in particular, `usePremiaAsCollateral = true` may allow theoretical short premia to be over-credited into collateral before they are economically realizable
- Why it is still worth digging:
  - The current offline suite now proves the intended high-level toggle semantics around short-credit inclusion vs `availablePremium`, including mixed-leg net-premium sign flips, but does not yet give a full exploit-style proof around:
    - `s_settledTokens`
    - `availablePremium`
    - checkpoint rebasing on mint/burn/liquidation
    - whether short-premium collateral credit ever runs ahead of realizable settlement
- What to probe next:
  - fork or heavier local integration around `settlePremium`, `_updateSettlementPostMint`, `_updateSettlementPostBurn`, and liquidation haircut flows
  - compare owed vs realizable premium before and after chunk pokes / burns / forced actions
  - specifically test whether theoretical short premia are ever counted as collateral too early under `usePremiaAsCollateral = true`
- Related review themes:
  - premium checkpoint integrity
  - seller-claimable premium bounded by actually settled tokens

---

### 15. Burn vs force-exercise economic consistency still needs differential validation
- Status: `Open candidate`
- Hypothesis:
  - for the same `tokenId` and same oracle snapshot, force exercise and ordinary burn may fail to reconcile to the same underlying unwind + settlement baseline except for explicit exercise fee
- Why it is still worth digging:
  - the current review already suggests that force exercise is structurally close to burn, with the main intended differences being trigger conditions, fee path, and semantics
  - that makes this a good differential target: if the two paths diverge by more than the explicit exercise-fee and intended sequencing differences, the mismatch is likely economically meaningful
  - the current offline differential harness only confirms the intended baseline shape: burn core plus an isolated exercise-fee overlay
- What to probe next:
  - construct same-position / same-snapshot comparisons between:
    - ordinary burn
    - force exercise
  - reconcile:
    - net token movement
    - premium realization
    - collateral release/seizure
    - post-action solvency
  - isolate what remains after subtracting explicit exercise fee
- Related review themes:
  - structural exercisable vs economic exercisable
  - premium checkpoint integrity
  - force-close fairness
- Related tests:
  - current characterization only: `PanopticPremiumExerciseSemantics.t.sol`

---

### 16. Liquidation / forced-action snapshot alignment risk remains the main unresolved high-severity surface
- Status: `Open candidate`
- Hypothesis:
  - even if branch routing is correct, value transfer during liquidation or force exercise may still be unfair due to:
    - stale storage reads
    - haircut ordering
    - bonus calculation under mixed premium states
    - snapshot mismatch between eligibility, burn, haircut, and final settlement
- Why it is still worth digging:
  - The offline tests now kill a lot of “wrong branch” theories, which concentrates risk into the actual economic settlement internals.
  - The strengthened liquidation differential harness now shows a sharper statement: same insolvency premise, different snapshot inputs can yield different eligibility views, different committed settlement amounts, and different final collateral reconciliation.
  - This aligns with the threat model’s highest-priority themes.
- What to probe next:
  - true integrated `dispatchFrom` liquidation / settle / force-exercise tests on a fork-capable harness
  - compare eligibility snapshot, burn snapshot, haircut snapshot, cost/bonus snapshot, and final collateral state
- Related review themes:
  - fully-collateralized invariant
  - liquidation / force-exercise edge cases and griefing resistance
  - premium haircut and settlement consistency
- Related tests:
  - current characterization only: `PanopticLiquidationSemantics.t.sol`

---

## Current Test Inventory

These issue candidates are informed by the current offline review harness:
- `PanopticBuilderWallet.t.sol`
- `PanopticCollateralVirtualShares.t.sol`
- `PanopticCoreSmoke.t.sol`
- `PanopticDispatchRouteSemantics.t.sol`
- `PanopticDispatchSemantics.t.sol`
- `PanopticFactoryBindings.t.sol`
- `PanopticLiquidationSemantics.t.sol`
- `PanopticPremiumExerciseSemantics.t.sol`
- `PanopticTokenIdSemantics.t.sol`

Current suite is predominantly offline/semantic and kills a number of branch-table and binding hypotheses, but does not yet fully validate live premium/liquidation economics against real Uniswap state transitions.
The strongest remaining uncertainty is not branch selection or initialization, but integrated value transfer across premium settlement, forced actions, and liquidation under real AMM state.

Current offline result:
- `FOUNDRY_OFFLINE=true forge test --offline --match-path 'test/Panoptic*.t.sol'`
- `98 passed, 0 failed`
