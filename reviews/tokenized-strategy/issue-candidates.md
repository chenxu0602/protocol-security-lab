# Issue Candidates

## Status Legend
- `Expected behavior`: matches current design, but is important enough to document
- `Review candidate`: potentially surprising or abusable behavior that needs more evidence
- `Not an issue`: useful negative result from testing

## 1. No-op honest report does not shift user claims
- Status: `Not an issue`
- Source:
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
  `testHonestHarness_MultiUser_NoOpReportDoesNotShiftClaims`
- Observation:
  Under an honest harness where `_harvestAndReport()` returns the real balance and no economic change occurs, `report()` does not change user claims or total supply.
- Why it matters:
  This is a useful baseline against which stale / overvalue behavior can be compared.
- Current conclusion:
  Good control case. Keep as baseline evidence, not as a finding.

## 2. Immediate post-report entrants can still share in locked value
- Status: `Expected behavior`
- Source:
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
  `testHonestMode_MultiUser_ImmediateLateDepositorSharesStillLockedValue`
- Observation:
  In honest mode, user B depositing immediately after a profitable `report()` still receives `100` shares for `100` assets, and after full unlock both users converge to the same claim.
- Why it matters:
  This is economically surprising if one expects reported profit to make immediate entry more expensive. Under the simplifying intuition you described, Bob entering immediately after `report()` but before any profit has unlocked still buys at `PPS = 1`, while Bob entering only after all profit has unlocked would instead buy at `PPS = 1200 / 1100`.
- Current interpretation:
  This appears to be a consequence of Yearn’s locked-profit design rather than a bug by itself.
- Follow-up:
  Document clearly in final review as an important economic behavior.

## 3. Mid-unlock entrants receive fewer shares than immediate post-report entrants
- Status: `Expected behavior`
- Source:
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
  `testHonestMode_MultiUser_MidUnlockLateDepositorGetsFewerShares`
- Observation:
  In honest mode, once part of the locked profit has unlocked, a later entrant receives fewer than `1:1` shares and has a smaller claim than the early user.
- Why it matters:
  Confirms that time itself changes entry pricing through effective supply decay.
- Current conclusion:
  Expected consequence of the unlock mechanism, but important for integrator and user mental models.

## 4. Stale reporting lets late entrants buy into unreported profit cheaply
- Status: `Review candidate`
- Source:
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
  `testStaleMode_MultiUser_LateDepositorBuysIntoUnreportedProfitCheaply`
- Observation:
  If `_harvestAndReport()` is stale and profit is not yet realized into stored accounting, a later depositor can still enter at the old price even though the strategy already has more real assets.
- Why it matters:
  This is the clearest version of the “late depositor buys into previously earned value” question from the threat model. Profit locking mitigates immediate post-report profit capture, but it does not prevent pre-report stale-price entry. If strategy value appreciates materially before a keeper-triggered `report()`, late entrants can acquire shares against outdated accounting and participate in gains they did not economically earn.
- Current interpretation:
  This is not a `TokenizedStrategy` math bug by itself; it is a direct consequence of delayed or stale strategy reporting. Depositor fairness therefore depends directly on reporting cadence and valuation freshness.
- What would upgrade it into a real finding:
  Evidence that realistic strategist / keeper behavior can systematically delay realization and create exploitable value transfer in production conditions.

## 5. Delayed realization improves late-entry pricing relative to honest pricing
- Status: `Review candidate`
- Source:
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
  `testStaleMode_MultiUser_DelayedRealizationBenefitsLateEntrantVsHonestPricing`
- Observation:
  Comparing two otherwise similar scenarios, the stale-report path gives the late entrant more shares than the honest-report path.
- Why it matters:
  This frames stale reporting as a cross-user transfer problem, not just a stale-oracle problem.
- Current interpretation:
  Strong review signal. The next question is whether this is merely “keeper timing risk” or rises to a meaningful unfairness / manipulability issue.
- Follow-up:
  Add tests around repeated deposits before delayed report to measure how much value can be transferred before realization.

## 6. Overvalued report can overcharge late depositors
- Status: `Review candidate`
- Source:
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
  `testOvervalueMode_MultiUser_InflatedReportOverchargesLateDepositor`
- Observation:
  If `_harvestAndReport()` overstates value, a later depositor receives fewer shares than warranted and can remain underwater even after the accounting corrects.
- Why it matters:
  This shows that the strategy callback is effectively a pricing oracle for all new entrants.
- Current interpretation:
  Very important trust-boundary result. Likely not a base-contract bug, but exactly the kind of accounting fragility that the review should emphasize.
- What would upgrade it:
  A realistic path showing how a strategist integration can accidentally or manipulably overvalue holdings during report.

## 7. Callback honesty is the main economic boundary, not just a coding detail
- Status: `Expected behavior`, but should be elevated in the review
- Source:
  Combined result of the honest / stale / overvalue test set in
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
- Observation:
  The shared `TokenizedStrategy` logic behaves coherently under honest reporting, while stale or inflated callback values immediately create economically different entry outcomes.
- Why it matters:
  This means `_harvestAndReport()` is not merely an implementation detail; it is the asset valuation oracle for the entire accounting system.
- Current conclusion:
  This should likely appear as a major review theme even if no formal vulnerability is ultimately claimed.

## 8. Optimistic reporting over-mints fee shares and worsens outcomes for users
- Status: `Review candidate`
- Source:
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
  `testOptimisticReport_OverMintsFeeSharesAndChangesUserOutcomes`
- Observation:
  When profit is overstated before `report()`, the strategy mints more fee shares and more locked shares than the honest path. After correction and full unlock, both the incumbent depositor and the later depositor end up with worse claims than in the honest-report comparison.
- Why it matters:
  This shows the damage is not limited to transient entry mispricing. Incorrect valuation at report time can permanently distort fee extraction and redistribute value away from users.
- Current interpretation:
  Stronger than the pure late-depositor pricing case because it shows optimistic accounting can amplify harm through protocol/strategist fee minting.
- What would upgrade it:
  Evidence that realistic integrations can overstate assets during harvest/report, even temporarily, and thereby mint excess fees in production.

## 9. Report timing alone changes who benefits from the same economic path
- Status: `Expected behavior`
- Source:
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
  `testReportTiming_ChangesUnlockAndDepositorOutcomesForSameEconomicPath`
- Observation:
  Two vaults with the same deposits and the same eventual profit produce different outcomes solely because one calls `report()` earlier. The early-report path starts unlock sooner, makes the later entrant receive fewer shares, and leaves more value with the incumbent depositor.
- Why it matters:
  Confirms that keeper/strategist timing is itself an allocation mechanism, not just an operational detail.
- Current interpretation:
  Likely expected under the locked-profit model, but important to document because users following the same economic path can get materially different outcomes depending only on when reports are posted.

## 10. Report frequency changes fee minting, unlock state, and late-entry outcomes even on the same PnL path
- Status: `Expected behavior`, but economically important
- Source:
  [YearnV3TokenizedStrategyReview.t.sol](/Users/chenxu/Work/protocol-security-lab/evm-playground/test/review/YearnV3TokenizedStrategyReview.t.sol)
  `testReportFrequency_SamePnLPath_ChangesUnlockScheduleAtDay10`
  and
  `testReportFrequency_SamePnLPath_ChangesLateEntrantAndIncumbentClaims`
- Observation:
  For the same real asset path (`1000 -> 1050 -> 1100`), reporting once at Day 10 versus reporting at Day 5 and Day 10 produces different Day 10 accounting state. The two-report path leaves fewer fee shares and fewer locked shares outstanding by Day 10, sets an earlier `fullProfitUnlockDate`, and changes the eventual Alice/Bob split after Bob enters post-report.
- Why it matters:
  This shows that reporting frequency is itself an economic parameter. Even when total realized PnL is identical, the cadence of reports changes fee extraction, remaining lock state, and who captures value. In practice, depositor fairness is a function of both how often the strategy reports and how fresh `_harvestAndReport()` valuations are when entrants arrive.
- Current interpretation:
  Likely intended under Yearn’s profit-locking design, but important enough to elevate in the review because keeper/report cadence materially affects user outcomes.
- Follow-up:
  Add variants where Bob enters between Day 5 and Day 10, and variants with protocol fees enabled, to map how sensitive the transfer is to report cadence.

## Next Candidates To Test
- Add `undervalue` mode to see whether under-reporting lets late entrants get penalized less or lets incumbents benefit at entrant expense
- Add withdraw / redeem tests under `_freeFunds()` shortfall to turn the exit-side trust boundary into issue candidates too
