# Function Notes

## Notes convention
- These notes are audit-oriented, not documentation-oriented.
- Focus is on:
  - state transition meaning
  - accounting anchors
  - trust boundaries
  - divergence risk between modules
  - concrete issue hypotheses worth testing
- Where code has not yet been fully stepped through, wording is kept at the level of “expected role / review focus” rather than pretending a specific implementation detail is confirmed.

---

## 1. Market bootstrap / registry / trust root

### `PanopticFactory.createPanopticPool(...)` / market deployment and registration
- Priority: critical
- Support tier: primary
- This is the market trust root.
- It binds:
  - one Uniswap pool
  - one PanopticPool
  - token0/token1 CollateralTrackers
  - risk/oracle configuration
  - any guardian / factory / SFPM references
- A bad bind here is not a local bug; it permanently corrupts the market’s accounting domain.

#### Why it matters
- Every later solvency check, premium settlement, collateral movement, and liquidation assumes this registry is correct.
- If token order, pool address, tracker assignment, or risk-engine wiring is wrong, later logic may be internally consistent but economically wrong.

#### Review focus
- Is the referenced Uniswap pool verified from canonical factory/state rather than trusted from user input?
- Are `token0` / `token1` read from the Uniswap pool itself, and then used consistently everywhere downstream?
- Are tracker assignments consistent with token order in:
  - Pool accounting
  - RiskEngine
  - liquidation / bonus logic
  - settlement / callback logic
- Is initialization single-use?
- If clones/proxies are used, can anyone front-run initialization or initialize with wrong references?
- Is market creation collision-resistant?
- Is there any privileged post-create mutation of core parameters that changes solvency semantics after users enter?

#### Main issue hypotheses
- Market created with inverted token/tracker assignment creates cross-token accounting corruption.
- Pool settlement uses one pricing/collateral domain while RiskEngine uses another.
- Factory initialization race / front-run can permanently poison a market.

---

## 2. PanopticPool main lifecycle entrypoints

This is the protocol execution surface users and liquidators actually touch.  
The most important thing to watch here is not just whether each function “works,” but whether the whole lifecycle preserves:

- position supply ↔ obligations bijection
- premium checkpoint integrity
- locked collateral monotonicity
- coherent oracle/risk snapshot use
- safe ordering around Uniswap callbacks and external token flows

---

### `PanopticPool.dispatch(...)`
- Priority: critical
- Support tier: primary
- This appears to be the main self-directed lifecycle entrypoint.
- Conceptually it routes user intent into:
  - mint new position
  - burn existing position
  - settle premium / checkpoint only
- In Panoptic, this matters because positions behave more like discrete tokenized objects than continuously resizable buckets.

#### Why it matters
- If `dispatch` chooses the wrong branch, or branch predicates are incomplete, protocol state can drift even if each subroutine is individually correct.
- This is also the highest-level place to verify “what state transition is actually allowed under current safety mode / solvency regime.”

#### Review focus
- How exactly does it distinguish:
  - new tokenId → mint
  - same tokenId same size → settle
  - same tokenId different size → burn / close path
- Does it ever permit implicit resize / top-up of an existing tokenId?
- Are there edge cases where a user can force a “settle-only” path when real exposure changed?
- Does it perform risk gating before or after routing into subcalls?
- Is the oracle snapshot used for dispatch-consumed subcalls coherent through the whole state transition?

#### Main issue hypotheses
- Branch selection allows state-desync between ERC1155 balances and internal exposure/premium state.
- A “settle-only” path may accidentally realize or unlock value that should require burn/health recheck.
- Same tokenId discrete-object semantics may be violated in corner cases.

---

### `PanopticPool.dispatchFrom(...)`
- Priority: critical
- Support tier: primary
- External-actor-forced action entrypoint.
- Not just a liquidation function.
- Conceptually routes third-party actions on another account into:
  - settle premium
  - force exercise
  - liquidation

#### Why it matters
- This is the enforcement portal for the entire risk system.
- If branch conditions are loose or economically mismatched, solvent accounts can be griefed, or insolvent accounts can escape correct liquidation.

#### Review focus
- What exact condition determines:
  - solvent → allow settle / force exercise
  - fully insolvent → allow liquidation
  - intermediate state → reject (`NotMarginCalled` style behavior)
- What does `positionIdListToFinal` length or shape mean operationally?
- Does force exercise always operate on a whole tokenId rather than a leg?
- Are liquidator / forcer permissions symmetric with the intended state machine, or can a caller choose a more favorable path than protocol intended?
- Is the same coherent oracle/risk snapshot used for:
  - action admissibility
  - exercise cost
  - liquidation bonus
  - haircut / residual loss treatment

#### Main issue hypotheses
- Branch encoding via array length / token list shape may be fragile and admit incorrect forced actions.
- Solvent accounts may be subject to economically abusive force exercise.
- Liquidation eligibility and liquidation economics may be computed under different snapshots.

---

### `PanopticPool._mintOptions(...)`
- Priority: critical
- Support tier: primary
- Core risk-increasing state transition.
- Introduces new option exposure, new premium baselines, and new collateral encumbrance.

#### Why it matters
- This is where bad debt is born if margin is understated.
- It is also where premium checkpoint bugs begin if new positions inherit historical accumulator state.

#### Review focus
- Does `_mintOptions` validate TokenId / leg structure before any value movement?
- How does it translate tokenId legs into per-token margin requirement?
- Does it lock collateral before or after AMM interaction?
- Are premium accumulator baselines established so new short liquidity does **not** inherit old premia?
- Does mint allow only risk-increasing exposure, or can it also be used for net risk reduction in safe mode?
- Is there a final health check after all settlement effects are known?

#### Premium-specific focus
- Is post-mint settlement just “checkpoint initialization,” or can mint accidentally realize prior premium?
- If a short leg adds liquidity to a chunk with existing premium history, how is the old history excluded from the new position?
- Are long and short legs within the same tokenId checkpointed consistently?

#### Main issue hypotheses
- Newly minted short exposure inherits historical premium accumulator state.
- Margin is checked too early, before final AMM / settlement liabilities are known.
- Multi-leg mint may create Pool-vs-RiskEngine divergence on required collateral.

---

### `PanopticPool._burnOptions(...)`
- Priority: critical
- Support tier: primary
- Core position-closing / forced-closing state transition.
- Realizes premium, realizes AMM-linked fee/inventory state, and releases collateral.

#### Why it matters
- This is the main “payout” path.
- If burn realizes too much value or unlocks too much collateral, funds are drained.
- If burn leaves stale checkpoint or stale removed-liquidity basis, future settlements break.

#### Review focus
- Is burn operating on full tokenId object semantics, or can a caller partially close substructure in a way accounting was not designed for?
- How are long vs short legs treated differently on burn?
- Is realized premium computed from:
  - current accumulator
  - prior per-leg snapshot
  - current liquidity / size
  in a way that is linear and idempotent?
- On short-leg burn, is remaining liquidity rebased so that already-settled premium is stripped out of history?
- On long-leg burn, are “payer side” obligations correctly moved into settled token pools without double counting?
- Is collateral released only after all debit-side obligations are finalized?

#### Main issue hypotheses
- Short burn rebase may let remaining liquidity inherit already-paid premium history.
- Long burn may move tokens into settlement pool with incorrect sign convention.
- Partial burn paths may be non-linear and break future accounting.

---

### `PanopticPool._settlePremium(...)` / premium-only settlement path
- Priority: high
- Support tier: primary
- Pure accounting realization path with no intended exposure change.

#### Why it matters
- This is exactly the kind of function that often looks harmless but leaks value if checkpoint ordering is wrong.
- It is also central to ensuring seller-claimable premium is bounded by actually settled/available tokens.

#### Review focus
- Does it change only accounting state, or does it also implicitly change withdrawability / collateral credits?
- Is `availablePremium` bounded by truly settled tokens rather than theoretical accumulator gain?
- Are seller-side premium claims and buyer-side obligations kept consistent under partial settlement?
- Can repeated settle calls collect the same premium twice?
- Does settle operate per leg, per tokenId, per chunk, or per account — and are those granularities aligned?

#### Main issue hypotheses
- Theoretical premium can be realized without enough settled token backing.
- Repeated settle paths can re-use stale per-leg or per-tokenId baselines.
- Seller-claimable premium and global settled token pools can drift.

---

### `PanopticPool.validateIsExercisable(...)`
- Priority: high
- Support tier: primary
- Structural gate for exercise eligibility.

#### Why it matters
- If this function is intentionally weak and only checks structural properties (e.g. has long leg, width nonzero), then it is **not** the real economic guardrail.
- In that case, the real protection must come from `exerciseCost(...)` and downstream settlement math.

#### Review focus
- Does it only check:
  - existence of long leg
  - width/range nonzero
  - token structure constraints
- Does it check any economic condition at all:
  - moneyness
  - oracle tick range
  - current price relation to strike/range
- If not, is that a deliberate design choice?
- Does the rest of the system assume exercise is only structural, or do comments/docs imply stronger semantics than code actually enforces?

#### Main issue hypotheses
- Exercise path is structurally valid but economically abusive.
- Documentation / mental model says “ITM exercise,” but implementation says “has a valid long leg.”

---

## 3. RiskEngine core financial logic

This is the real heart of Panoptic’s solvency model.

PanopticPool mostly orchestrates.
RiskEngine decides:
- when an account is solvent
- how much collateral is required
- what exercise should cost
- what liquidation bonus is fair
- how residual loss is socialized / clawed back

Any mismatch here is not a local bug; it changes the economic law of the whole protocol.

---

### `RiskEngine.isAccountSolvent(...)`
- Priority: critical
- Support tier: primary
- Solvency decision root.

#### Why it matters
- Every meaningful safety gate eventually depends on this.
- If this understates required collateral, the protocol accumulates bad debt.
- If it overstates requirements inconsistently, liquidation / force exercise can become abusive.

#### Review focus
- What exact account state is consumed?
  - tokenIds / balances
  - tracker balances / shares
  - locked collateral
  - margin loans / utilization state
- What oracle snapshot is used?
  - spot
  - TWAP
  - bounded combination
  - safe-mode override
- Is solvency checked under multiple stress ticks / bands or a single mark?
- Is the same logic used consistently across:
  - dispatch admission
  - withdraw admission
  - liquidation eligibility
  - post-close safety checks
- Does “solvent” mean fully collateralized under worst case, or just above a softer maintenance threshold?

#### Main issue hypotheses
- Solvency formula used for entry differs from solvency formula used for liquidation.
- Multi-leg aggregation may net legs in a way settlement paths do not actually support.
- Snapshot incoherence may allow one price for admissibility and another for economics.

---

### `RiskEngine._getMargin(...)`
- Priority: critical
- Support tier: primary
- Defines capital requirement at the leg and/or portfolio level.

#### Why it matters
- This is where Panoptic’s option semantics become capital rules.
- Your earlier understanding strongly suggests:
  - `width == 0` short behaves like loan-style / 100% + maintenance
  - `width != 0` short behaves like Reg-T-style option margin with utilization/moneyness dependence
  - long has a decaying buying-power style requirement rather than pure zero
- This function needs to be understood precisely, not approximately.

#### Review focus
- How does margin differ for:
  - short vs long
  - call-like vs put-like
  - width zero vs width nonzero
  - near-range vs far-from-range
  - high utilization vs low utilization
- Is required collateral computed as a max of multiple scenarios/branches?
- Are the scenarios economically interpretable?
- Does the margin formula decay/step in a way that is monotone with risk?
- Are there discontinuities at:
  - tick boundary
  - strike boundary
  - utilization thresholds
- Is aggregation across legs conservative enough?

#### Main issue hypotheses
- Margin can drop discontinuously at specific tick/width/utilization boundaries.
- Long/short symmetry assumptions may be broken by sign or token-domain handling.
- Max-of-branches logic may miss the true worst case for some multi-leg portfolios.

---

### `RiskEngine.exerciseCost(...)`
- Priority: critical
- Support tier: primary
- Real economic guardrail for force exercise.

#### Why it matters
- If `validateIsExercisable` is only structural, then `exerciseCost` is where Panoptic decides whether forced close is fair.
- This function likely determines whether structurally exercisable positions can be closed at economically sensible prices.

#### Review focus
- What exact state goes into exercise cost?
  - oracle tick / TWAP
  - token-specific margin state
  - premium already paid/owed
  - leg structure
- Is cost computed at:
  - current mark
  - conservative mark
  - bounded mark
- Is exercise cost aligned with the same assumptions used by:
  - solvency checks
  - liquidation bonus
  - burn settlement
- Can cost be negligible or oddly favorable in scenarios where forced close should intuitively be expensive?

#### Main issue hypotheses
- Force exercise may be economically underpriced relative to true risk transferred.
- Exercise cost may be computed under a weaker oracle regime than liquidation.
- A structurally valid long-containing tokenId may be force-closable in states that amount to griefing.

---

### `RiskEngine.getLiquidationBonus(...)`
- Priority: critical
- Support tier: primary
- Determines liquidator incentive and protocol residual loss interaction.

#### Why it matters
- This is a direct value-transfer formula.
- If too small, liquidation may fail in practice.
- If too large, liquidators can over-extract collateral.
- If cross-token offset logic is wrong, value can move across domains incorrectly.

#### Review focus
- Is bonus computed from relieved exposure, seized collateral, or both?
- How are cross-token surplus / deficit situations handled?
- Is there explicit logic preventing inflated balance / loaned balance from boosting bonus?
- Can bonus be paid partly in one token and topped up by another?
- Are these cross-token conversions using the same conservative oracle basis as solvency?

#### Main issue hypotheses
- Cross-token compensation may create extraction beyond intended incentive.
- Inflated or borrowed balances may improperly enlarge liquidator reward.
- Bonus formula may not be monotone with exposure actually removed.

---

### `RiskEngine.haircutPremia(...)`
- Priority: critical
- Support tier: primary
- Residual bad-debt recovery / premium clawback path.

#### Why it matters
- This is not ordinary settlement; it is the “bad state cleanup” mechanism.
- It determines how protocol loss is socialized back into already-paid long premium.
- Bugs here may not show in healthy paths, but become devastating in tail events.

#### Review focus
- When exactly is haircut triggered?
- Is protocol loss first identified per token, then netted cross-token?
- How is long-paid premium aggregated?
- If same-token premium is insufficient, how is cross-token substitution valued?
- Is haircut allocation proportional per long leg?
- Does upward rounding create systematic over-clawback?

#### Main issue hypotheses
- Haircut allocation may overcharge some long legs versus proportional share.
- Cross-token substitution may use inconsistent valuation basis.
- Aggregate haircut may exceed actual protocol loss under rounding.

---

### `RiskEngine` oracle mode / safe-mode logic
- Priority: high
- Support tier: primary
- Defines when protocol trusts spot, TWAP, or conservative bounded price bands.

#### Why it matters
- Panoptic is exposed to AMM price manipulation unless this layer is coherent.
- Safe mode is not just a pause switch; it changes the economic admissibility regime.

#### Review focus
- What exact condition moves the protocol into safe mode?
- What actions remain allowed in safe mode?
  - close-only?
  - force exercise?
  - liquidation?
  - premium settlement?
  - deposits / withdrawals?
- Does safe mode block only risk-increasing actions, or also some risk-reducing actions?
- Are there distinct oracle windows for:
  - opening risk
  - closing risk
  - liquidation
  - force exercise
- Are those windows coherent inside one state transition?

#### Main issue hypotheses
- Safe mode may accidentally block risk reduction.
- Different functions may use different price bands in the same regime.
- A privileged or timing-driven safe-mode transition may create selective liquidation opportunities.

---

### `RiskEngine` utilization / margin-loan hooks
- Priority: medium
- Support tier: primary
- Secondary but important if Panoptic internally supports loan-like collateral usage or tracker-credit mechanics.

#### Why it matters
- Utilization-dependent logic often creates boundary bugs.
- Loan-like accounting can silently create negative withdrawable or bad debt if it is not perfectly synchronized with collateral state.

#### Review focus
- Is utilization sampled from real vault assets and AMM encumbrance consistently?
- Can utilization be manipulated intra-tx to reduce margin requirement?
- If internal margin loans exist, can they only support closing/settlement, or also opening risk?
- Are loan balances token-specific and priced conservatively?

#### Main issue hypotheses
- Flash changes in utilization may reduce margin requirement temporarily.
- Margin-loan state may drift from tracker/account balances.
- Loan + liquidation ordering may undercharge liquidatee relative to bonus + debt.

---

## 4. CollateralTracker accounting layer

Each CollateralTracker is a single-token accounting domain.  
This is easy to forget because PanopticPool’s risk is two-token / portfolio-shaped, but the collateral state itself is stored per token.

That means cross-token correctness often fails not in PanopticPool, but in “who told which tracker to do what, and when.”

---

### `CollateralTracker.deposit(...)` / `mint(...)`
- Priority: critical
- Support tier: primary
- Main value-ingress path into a single collateral domain.

#### Why it matters
- Any share inflation or reentrancy here undermines the entire solvency layer.

#### Review focus
- Is share issuance based on actual received assets or requested assets?
- Does token transfer happen before or after share mint/accounting update?
- Is there explicit support or rejection for:
  - fee-on-transfer
  - ERC777
  - rebasing
  - weird zero-transfer behavior
- Is totalAssets taken from actual balance, internal accounting, or both?

#### Main issue hypotheses
- Requested-amount share minting over-credits fee-on-transfer deposits.
- Reentrancy may mint against stale totals.
- Direct token transfers may desync true assets vs tracked assets.

---

### `CollateralTracker.withdraw(...)` / `redeem(...)`
- Priority: critical
- Support tier: primary
- Main value-egress path from a single collateral domain.

#### Why it matters
- This is where “shares look fine” meets “but are they actually withdrawable after margin lock?”
- A bug here is either direct drain or user funds stuck.

#### Review focus
- Is every withdrawal path health-checked through the same risk logic?
- Are locked / encumbered amounts always subtracted conservatively?
- Is burn-before-transfer ordering respected?
- Can allowance-based third-party withdrawal create owner/receiver confusion?
- In safe mode, what withdrawals remain allowed?

#### Main issue hypotheses
- Locked collateral underflow bricks withdrawals.
- Third-party redeem path may bypass intended health checks.
- Risk check may use weaker assumptions than liquidation path.

---

### `CollateralTracker` lock/unlock / settle hooks invoked by PanopticPool
- Priority: critical
- Support tier: primary
- Internal accounting mutation surface where Pool tells Tracker:
  - lock more
  - unlock some
  - credit/debit settlement
  - apply liquidation / haircut effects

#### Why it matters
- This is the seam between portfolio logic and single-token vault logic.
- Many system-level bugs live here because each side is individually reasonable but the mapping is wrong.

#### Review focus
- Are these functions restricted to the intended Pool?
- Is authorized Pool immutable?
- Are all internal bucket updates conservative and non-negative?
- Can Pool accidentally call tracker0 with token1 semantics or vice versa?
- Does tracker trust Pool’s deltas blindly, or verify any invariant locally?

#### Main issue hypotheses
- Cross-token tracker mix-up corrupts solvency without obvious local revert.
- Lock/unlock sequences may temporarily create withdrawable collateral if reentrancy exists.
- Global totals may drift from per-account buckets.

---

### `CollateralTracker.delegate(...)`
- Priority: high
- Support tier: primary
- Part of the virtual-share based delegation / refund / collateral routing design.

#### Why it matters
- This is a nonstandard mechanism and therefore audit-relevant even if it is not the biggest notional flow.
- Any “virtual anchor balance” mechanism deserves extra skepticism.

#### Review focus
- What exact state is moved or authorized by delegation?
- Does delegation rely on a virtual target balance or synthetic share anchor?
- Is delegate bookkeeping reversible and bounded?
- Can delegation make withdrawable or refundable balances look larger than reality?

#### Main issue hypotheses
- Virtual-share anchor may create confusion between synthetic accounting baseline and real claimable assets.
- Delegation may alter refundability or borrowability in a way later functions misinterpret.

---

### `CollateralTracker.revoke(...)`
- Priority: high
- Support tier: primary
- Reverse path of delegate.

#### Why it matters
- Reversals are where virtual accounting systems often break, especially when partial state has already been consumed by other actions.

#### Review focus
- Does revoke fully restore original accounting relationship?
- What happens if delegated balances were partially consumed / settled / haircut in the meantime?
- Can revoke underflow or trap balances?
- Is revoke allowed while account is margin called or in liquidation flow?

#### Main issue hypotheses
- Revoke may assume pristine delegation state and fail under partially consumed paths.
- Revoke may recreate refundable balances that were already economically spent.

---

### `CollateralTracker.getRefundAmounts(...)`
- Priority: high
- Support tier: primary
- Key interpretation function for the virtual-share / refund anchor mechanism.

#### Why it matters
- Your prior notes already flagged this as a suspicious conceptual surface:
  - use of `type(uint248).max`
  - synthetic anchor semantics
  - possible confusion between “virtual reference point” and “real balance state”

#### Review focus
- What exactly is being measured against the virtual anchor?
- Is the function intended to return a real token refund amount, or an internal synthetic delta later converted elsewhere?
- Can return values exceed economically justified bounds?
- Are casts / truncations safe given the huge anchor?
- Does the function rely on a precondition that `balanceOf(payor)` has been shifted near the anchor beforehand?

#### Main issue hypotheses
- Virtual anchor arithmetic may overflow / mis-sign in edge cases.
- Returned refund amount may be interpreted as real withdrawable value when it is only an internal reference delta.
- Delegate/revoke/getRefundAmounts may only be self-consistent under assumed call order, not adversarial order.

---

## 5. Uniswap / SFPM integration / callback boundary

This is the principal external execution boundary.  
The most important audit question here is:

**Can Panoptic ever be left in a partially updated state while Uniswap-driven token obligations are still live or manipulable?**

---

### `_createPositionInAMM(...)` / `_createLegInAMM(...)` and related AMM-facing internal routines
- Priority: critical
- Support tier: primary
- Internal bridge from Panoptic semantics to Uniswap liquidity operations.

#### Why it matters
- This is where “short adds liquidity / long removes liquidity” becomes real token movement and fee-growth exposure.
- If Pool’s mental model of a leg does not match actual AMM actions, settlement and margin diverge.

#### Review focus
- Does each leg deterministically map to the intended liquidity action?
- Are call-like / put-like semantics translated consistently across asset domains?
- Is the sign convention between long/short and add/remove liquidity stable?
- Are per-leg collect amounts treated as raw AMM collection rather than immediately assumed to be “premium earned”?

#### Main issue hypotheses
- Long/short AMM action mapping may be internally consistent but economically mislabeled in comments or downstream accounting.
- `collectedByLeg` style values may be misinterpreted as realized premium rather than gross collected token movement.

---

### Uniswap callback handlers / V3 callbacks / V4 hook-equivalent flows
- Priority: critical
- Support tier: primary
- Mid-transition payment portal.

#### Why it matters
- These are reentrancy portals and confused-deputy surfaces.
- Any stale cached payer/delta/context bug here is immediately dangerous.

#### Review focus
- Is caller authentication exact?
- Is callback state scoped per in-flight operation, not globally reusable?
- Are temporary storage variables cleared on all success paths?
- Can callback be invoked when no AMM action is active?
- Are token payments sourced from the right accounting domain?

#### Main issue hypotheses
- Stale callback context may let one action pay from another user/account context.
- Reentrancy may reach Pool/Tracker before checkpoints are finalized.
- Token-domain confusion may charge wrong tracker/user.

---

## 6. Position encoding / TokenId / leg semantics

Panoptic lives or dies by whether every module means the same thing when it looks at a TokenId.

---

### `TokenId` decode / leg extraction / validation helpers
- Priority: critical
- Support tier: primary
- Canonical position semantics surface.

#### Why it matters
- If Pool, RiskEngine, and settlement helpers decode differently, protocol accounting can be “locally correct, globally false.”

#### Review focus
- Is decode logic shared or duplicated?
- Are all bit widths / sign conventions / enums range-checked?
- Are tokenType, isLong, asset, riskPartner, strike, width, ratio all interpreted identically across modules?
- Is there canonical leg ordering?
- Can unused bits or alternate encodings create multiple IDs for same economics?

#### Main issue hypotheses
- Duplicate economic positions with distinct IDs may bypass uniqueness / accounting expectations.
- Decode divergence may let RiskEngine see a safer position than settlement actually enforces.
- Range/cast bugs may create malformed but accepted legs.

---

## 7. Premium / fee-growth / checkpoint integrity

This deserves its own section because Panoptic’s accounting bugs are likely to come from **baseline consistency**, not just simple token conservation.

---

### Premium / fee settlement routines (`_getPremia`, settlement updates, checkpoint refresh logic)
- Priority: critical
- Support tier: primary
- Determines what premium is theoretically accrued, what is actually settled, and what is actually claimable.

#### Why it matters
- The protocol can be “conserved in aggregate” but still wrong per user/per leg/per exit path.
- This is exactly the family where:
  - mint inherits old premia
  - burn leaves stale claims
  - long/short sign is flipped
  - settled pool and theoretical pool drift apart

#### Review focus
- What is theoretical premium?
- What is settled premium?
- What is available premium?
- Where are the checkpoints:
  - per account?
  - per tokenId?
  - per leg?
  - per chunk?
- Are snapshots updated before any externalized token transfer or credit?
- Is there a strict one-way transition from theoretical accrual → settled pool → claimable amount?

#### Main issue hypotheses
- Seller may claim theoretical premium unsupported by settled token pool.
- Repeated updates may re-use stale snapshots.
- Remaining-liquidity rebase after partial burn may be wrong.

---

### `_updateSettlementPostMint(...)`
- Priority: high
- Support tier: primary
- Post-mint baseline establishment.

#### Why it matters
- New positions must start with correct premium basis.
- This is where “don’t inherit old premium” is enforced.

#### Review focus
- Does it set gross premium baseline for new short liquidity correctly?
- Does it only initialize accounting, or can it accidentally settle historical value?
- Is any baseline set differently for long vs short legs?
- Are chunk-level settled pools affected or only snapshots?

#### Main issue hypotheses
- New short liquidity may whitewash into old premium history.
- Mint path may accidentally touch realized/settled pools rather than just baselines.

---

### `_updateSettlementPostBurn(...)`
- Priority: critical
- Support tier: primary
- Post-burn realization and rebase.

#### Why it matters
- More complex than post-mint because it:
  - realizes value for exiting liquidity
  - preserves correct history for remaining liquidity
  - may move buyer-paid premium into settled pools
- This is a prime candidate for subtle accounting drift.

#### Review focus
- For short burn:
  - how is available premium bounded?
  - how is remaining baseline rebased?
- For long burn:
  - how are negative premia / payer obligations settled?
  - how do settled token pools move?
- Does exiting liquidity take exactly its rightful share of accrued premium history?

#### Main issue hypotheses
- Short burn rebase may either over-strip or under-strip history from remaining liquidity.
- Long burn may update settled pools with wrong sign or double effect.
- Partial exits may be non-linear.

---

## 8. Suggested next code-walk order

To keep notes connected to actual audit progress, the next detailed code walk should go in this order:

1. `PanopticPool.dispatch`
2. `PanopticPool.dispatchFrom`
3. `PanopticPool._mintOptions`
4. `PanopticPool._burnOptions`
5. premium settlement helpers:
   - `_getPremia`
   - `_updateSettlementPostMint`
   - `_updateSettlementPostBurn`
   - `_settlePremium`
6. `RiskEngine.isAccountSolvent`
7. `RiskEngine._getMargin`
8. `RiskEngine.exerciseCost`
9. `RiskEngine.getLiquidationBonus`
10. `RiskEngine.haircutPremia`
11. `CollateralTracker.delegate`
12. `CollateralTracker.revoke`
13. `CollateralTracker.getRefundAmounts`
14. callback / AMM integration paths

---

## 9. Candidate issue buckets to validate with tests

These are not findings yet; they are the most promising hypothesis buckets from the current reading state.

### A. Premium checkpoint inheritance / stale baseline reuse
- New liquidity inherits old premium history
- Remaining liquidity after burn keeps history that should have been stripped
- Settle-only path can repeatedly realize stale deltas

### B. Structural exercise vs economic fairness mismatch
- `validateIsExercisable` is intentionally weak
- `exerciseCost` may be the only real guard
- force exercise may be economically abusive though structurally valid

### C. Cross-token tracker / accounting-domain confusion
- token0/token1 tracker calls may be mismatched
- liquidation bonus / haircut may move value across tokens inconsistently
- Pool and RiskEngine may agree locally but disagree globally on token domain

### D. Margin discontinuity / wrong worst-case branch
- `_getMargin` may drop too sharply at width/tick/utilization thresholds
- max-of-branches logic may omit true worst case
- multi-leg aggregation may over-net risk

### E. Virtual-share delegate / revoke / refund inconsistency
- synthetic anchor arithmetic may not be adversarially robust
- revoke after partial consumption may recreate value
- refund amount may be misinterpreted as real claim rather than reference delta

### F. Safe-mode / oracle incoherence
- different state transitions may use different oracle windows
- safe mode may block risk reduction or enable selective forced actions
- privileged/timing transitions may distort liquidation fairness

### G. Callback-state / reentrancy confusion
- stale callback context reused across operations
- external calls happen before checkpoints finalize
- wrong payer/account context used during AMM payment