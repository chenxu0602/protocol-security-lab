# Invariants

Invariants below are phrased to be directly testable via Foundry invariants/fuzzing by instrumenting PanopticPool/CollateralTracker/RiskEngine and comparing on-chain balances, internal share/accounting, premium checkpoints, and oracle snapshots.

Where exact variable names differ, treat expressions as semantic:
- `assets` = underlying token balance held/controlled by tracker/pool
- `shares` = tracker ERC20 share supply
- `health` = RiskEngine margin/solvency output under bounded oracle ticks
- `premium checkpoint` = the stored per-owner/per-tokenId/per-leg accumulator baseline (for example `s_options[owner][tokenId][leg]`)
- `theoretical premia` = accumulator-derived premia from `_getPremia()`
- `settled premia` = premium amounts actually realized into settlement pools / token balances
- `available premia` = premium amounts actually available to be credited/claimed after settlement constraints

A minority of entries are `scenario_hypothesis`: these are high-suspicion test scenarios rather than always-true relations, useful for exploit search/regression (notably ERC777/hook reentrancy, force exercise fairness, and partial-close rounding).

---

## Market creation / binding invariants (Factory + Pool init)

### 1. Uni pool binding is immutable and self-consistent (token0/token1, tickSpacing, fee tier)
- Type: invariant
- Priority: critical

#### Statement
- For each PanopticPool, the referenced Uniswap pool address (or pool key) and its token0/token1 ordering, fee tier, and tickSpacing are immutable after initialization.
- The pool’s CollateralTracker0 underlying token == Uniswap.token0 and CollateralTracker1 underlying token == Uniswap.token1 (never swapped).
- All risk/oracle conversions and settlement paths use the same token ordering as Uniswap (no path uses inverted ordering).

#### Why It Matters
- Any mismatch causes systemic mispricing in margin, fee attribution, and liquidation seizure; it is not recoverable per-market.

#### Relevant Mechanisms
- `PanopticFactory.create/deployMarket`
- `PanopticPool.initialize`
- `CollateralTracker constructor/init`
- `RiskEngine price conversions`

#### What Could Break It
- Factory fails to authenticate the Uniswap pool (accepts non-Uniswap address) or reads token0/token1 from wrong interface (v3 vs v4).
- Re-init or upgrade-like path mutates references.
- A single conversion helper assumes token order opposite to initialization, causing silent value inversion.

#### Review Intent
- Invariant test: deploy a market and assert token addresses/tickSpacing/fee tier match the canonical Uniswap pool and remain unchanged across all state transitions.

---

### 2. One Uniswap pool maps to at most one PanopticPool (no registry split)
- Type: invariant
- Priority: high

#### Statement
- For any Uniswap pool address/key, `Factory.registry[uniswapPool]` is either zero or a single PanopticPool that never changes.
- Creating a market for an already-registered Uniswap pool must revert (or be idempotent returning the same pool) and must not allow different parameterization for the same underlying pool.

#### Why It Matters
- Split markets break fee growth reconstruction and can confuse oracle/safe-mode parameters, enabling accounting drift or user loss.

#### Relevant Mechanisms
- `PanopticFactory registry/mapping`
- `createPool/deployMarket`

#### What Could Break It
- Missing uniqueness check or differing key normalization (e.g., token order not canonicalized) allowing duplicates.
- Using v3 address vs v4 key inconsistently causing two entries for same market.

#### Review Intent
- Fuzz create with permuted token order/fee tiers and assert duplicates cannot be created.

---

### 3. Initialization is single-shot and leaves no unsafe approvals
- Type: invariant
- Priority: high

#### Statement
- `PanopticPool.initialize` can be successfully executed at most once; any subsequent call must revert.
- Post-initialize, any ERC20 approvals granted by pool/trackers are limited to the intended spender(s) (e.g., Uniswap pool/manager) and not to arbitrary addresses; approval targets are immutable or strictly controlled.

#### Why It Matters
- Re-init is catastrophic (can redirect collateral plumbing). Overbroad approvals enable token draining via compromised/incorrect spender.

#### Relevant Mechanisms
- `initializer/onlyFactory guards`
- `ERC20 approve flows to Uniswap/trackers`

#### What Could Break It
- Missing initializer guard on one of multiple init functions (v3 vs v4) or delegatecall pattern.
- Approvals set before binding validation, allowing attacker-controlled addresses to become spenders.

#### Review Intent
- Scenario/invariant tests: attempt re-init; check allowances after init are as expected and do not change during normal operations.

---

## CollateralTracker vault accounting invariants (shares, assets, loans/utilization)

### 4. Share/asset conservation (ERC4626-like) under deposits/withdrawals/fee credits
- Type: invariant
- Priority: critical

#### Statement
- For each CollateralTracker `T` with underlying token `U`, define:
  - `assetsHeld = U.balanceOf(T) + any assets held in pool escrow on behalf of T - any accounted liabilities explicitly tracked by T`.
- At all times, `totalSharesSupply > 0` implies `sharePrice = assetsHeld / totalSharesSupply` is well-defined and changes only due to real economic events:
  - net token inflow/outflow
  - realized fees/premia credited
  - explicit protocol-defined loss events
- A single deposit/withdraw must satisfy:
  - `ΔassetsHeld` equals actual token transfer (`balanceAfter - balanceBefore`) plus/minus any internal protocol transfers
  - minted/burned shares correspond to that `ΔassetsHeld` using the tracker’s conversion function, up to bounded rounding

#### Why It Matters
- Prevents ‘free shares’ minting and ensures the tracker cannot drift from underlying reality; central to solvency.

#### Relevant Mechanisms
- `CollateralTracker.deposit/withdraw/redeem`
- fee crediting from `PanopticPool`
- utilization/margin-loan bookkeeping

#### What Could Break It
- Using nominal `amount` instead of actual received amount (fee-on-transfer/deflationary tokens) mints excess shares.
- Rebasing tokens change balance without being reflected in accounting (either should be disallowed or handled explicitly).
- Unsigned underflow in liabilities makes `assetsHeld` appear higher or lower than reality.

#### Review Intent
- Invariant test comparing internal accounting to actual ERC20 balances across random sequences of deposits/withdrawals/crediting.

---

### 5. Withdrawals are maintenance-safe and cannot bypass via alternate entrypoints
- Type: operational_property
- Priority: critical

#### Statement
- Any call path that results in net decrease of an account’s collateral in either tracker (withdraw, redeem, transfer-out to receiver, or any ‘collect to user’ mode) must enforce that the account remains at or above maintenance margin immediately after the action, using the same bounded oracle snapshot as liquidation eligibility/pricing for that transaction.
- If `owner != msg.sender`, allowance-based withdrawals must still perform the same maintenance check against the owner’s positions (not the caller’s).

#### Why It Matters
- Prevents users from escaping margin requirements by choosing a different function signature/receiver.

#### Relevant Mechanisms
- `CollateralTracker.withdraw/redeem`
- `PanopticPool/RiskEngine` health check hooks
- oracle snapshotting

#### What Could Break It
- Solvency check performed only in one of withdraw vs redeem.
- Maintenance check uses spot while liquidation uses TWAP bounds (or vice versa).
- Check performed pre-transfer but reentrancy changes positions/collateral before state commit.

#### Review Intent
- Differential fuzz: attempt withdrawals through every exposed method and ensure all fail/succeed identically for same economic state.

---

### 6. No hidden ‘negative collateral’ via fee/premia accounting fields
- Type: invariant
- Priority: high

#### Statement
- Per-account credited amounts and owed/debt-like fields in CollateralTracker (fees, premia, removedLiquidity, utilization loans) must never cause an account to be able to withdraw more underlying than their pro-rata claim on `assetsHeld` minus any explicitly tracked liabilities.
- If the design uses signed accounting internally but stores unsigned, then:
  - values must be clamped/checked to prevent underflow
  - any deficit must make the account insolvent/blocked rather than wrapping

#### Why It Matters
- Underflow/overflow in these fields historically causes DoS or theft and directly impacts ability to withdraw or liquidate.

#### Relevant Mechanisms
- `CollateralTracker.updateOwed/settlePremium/creditFees`
- `removedLiquidity tracking`
- utilization/margin-loan modules

#### What Could Break It
- Underflow on repeated partial closes or fee settlement sequences.
- Overflow in premia accumulator causing revert/DoS.

#### Review Intent
- Property-based test over long sequences: ensure all tracked accumulators remain within safe bounds and withdrawals never exceed realizable assets.

---

### 7. Virtual-share delegation/refund cannot create redeemable value
- Type: invariant
- Priority: critical

#### Statement
- Any `delegate(...)`, `revoke(...)`, `getRefundAmounts(...)`, or equivalent virtual-share/virtual-anchor path must not create new economically redeemable value.
- A purely synthetic accounting anchor (for example large virtual share values) may change internal reference points, but must not increase:
  - total redeemable assets of all users combined
  - per-user withdrawable assets beyond what real tracker assets support
- After a delegate→consume/settle→revoke sequence, revoke must not restore value already economically spent.

#### Why It Matters
- Panoptic’s virtual-share machinery is more exotic than standard vault accounting; this is exactly the kind of place where synthetic anchors can be mistaken for real claims.

#### Relevant Mechanisms
- `CollateralTracker.delegate`
- `CollateralTracker.revoke`
- `CollateralTracker.getRefundAmounts`
- virtual shares / virtual assets state

#### What Could Break It
- `getRefundAmounts()` returning a real-valued refund based on a synthetic anchor without sufficient backing.
- Revoke assuming pristine delegation state even after partial economic consumption.
- Overflow/sign bugs around very large virtual reference values.

#### Review Intent
- Stateful fuzz over delegate/revoke/refund sequences, including partial burns, fee settlement, and liquidation interleavings; assert total redeemable value never increases absent real inflow.

---

## RiskEngine / oracle invariants (bounds, coherence, monotonicity)

### 8. Single coherent oracle snapshot per transition (no intra-tx price switching)
- Type: operational_property
- Priority: critical

#### Statement
- Within a single state transition that:
  - checks margin/eligibility, or
  - prices liquidation/exercise/withdrawal/burn settlement,
  all computations must use one coherent oracle view:
  - same TWAP window
  - same bound ticks
  - same spot reference if used
  - same tickSpacing rounding conventions
- If the protocol caches bounds per-block or per-call, then any subsequent reads in the same transaction must return identical bounds unless explicitly updated in that call path.

#### Why It Matters
- Prevents ‘pass checks under one price, settle under another’ manipulation and makes liquidation/withdraw gating reliable.

#### Relevant Mechanisms
- `RiskEngine.getBounds/updateOracle`
- `PanopticPool mint/burn/liquidate/exercise`
- `CollateralTracker withdraw gating`

#### What Could Break It
- Mixing spot for gating and TWAP for seize (or vice versa).
- Bounds recomputed after external calls where spot has moved or attacker manipulates observations.
- Different helper functions round ticks in different directions.

#### Review Intent
- Instrument tests to capture bounds used at each step; assert equality across gating + settlement in same tx.

---

### 9. Oracle bounds are conservative and widen under safe mode (never narrower than stressed normal mode)
- Type: operational_property
- Priority: high

#### Statement
- When safe mode is triggered due to staleness/deviation, any bounded price range used for margin/liquidation/exercise must be at least as conservative as normal mode:
  - required margin should not decrease
  - liquidation/exercise fairness should not improve for risky users due to narrower bounds
- If oracle data is unavailable/insufficient, sensitive operations must revert or default to a conservative bound, not a permissive spot-only bound.

#### Why It Matters
- Oracle stress is precisely when undercollateralization risk is highest; permissive fallback enables toxic position opens/withdrawals.

#### Relevant Mechanisms
- `RiskEngine safeMode flag`
- observation reads and fallback logic

#### What Could Break It
- Fallback-to-spot on observe failure.
- Incorrect inequality/rounding that tightens bounds in safe mode.
- Safe mode checked in mint but not in withdraw, liquidation, or exercise pricing.

#### Review Intent
- Scenario tests that force observation failures and safe-mode toggles; assert operations revert or become more conservative.

---

### 10. Margin requirement monotonicity with respect to size and adverse price movement
- Type: invariant
- Priority: critical

#### Statement
- For any fixed position structure (legs, strikes, widths, long/short flags) and fixed oracle bounds, increasing the absolute size/ratio of net short exposure must not decrease required initial or maintenance margin.
- For any fixed account state, if the oracle bound moves adversely for the account, required maintenance margin must not decrease.

#### Why It Matters
- Prevents discontinuities/rounding artifacts that allow larger toxic shorts with less collateral.

#### Relevant Mechanisms
- `RiskEngine.computeMargin/accountHealth`
- tick/ratio rounding and casting

#### What Could Break It
- Tick rounding toward favorable side for shorts.
- Integer truncation in size→liquidity or exposure conversion.
- Cross-leg netting rules that over-credit hedges.

#### Review Intent
- Fuzz across random positions and compare `margin(size)` for `size` and `size+1`; compare margin at worstBound vs midBound.

---

## Position lifecycle & settlement invariants (PanopticPool)

### 11. Open/close value conservation across pool + trackers + Uniswap (bounded rounding)
- Type: invariant
- Priority: critical

#### Statement
- For each mint/open or burn/close (including partial): the net change in:
  - token0 assets held by system
  - token1 assets held by system
  equals the net external flows to/from the user plus:
  - fees paid to Uniswap
  - any protocol-defined fee/treasury skim
  - any explicitly tracked settlement transfers,
  up to explicitly bounded rounding.
- No path may create net assets from nothing: if user receives tokens on close, those tokens must come from:
  - their collateral claim
  - counterparties’ collateral via premia/fee transfers
  - Uniswap fees actually collected
  - explicit swap/settlement flows actually executed
- Importantly, no invariant may assume `swapInAMM()` perfectly neutralizes ITM amounts; any residual inventory after convenience netting must still be correctly reflected in settlement/collateral accounting.

#### Why It Matters
- Catches free-option bugs, double-crediting, incorrect Uniswap collect attribution, and over-optimistic assumptions about ITM netting.

#### Relevant Mechanisms
- `PanopticPool mint/burn`
- `Uniswap mint/burn/collect/swap interactions`
- `CollateralTracker credit/debit`
- `swapInAMM`

#### What Could Break It
- Using inconsistent sign conventions for token0/token1 deltas.
- Collecting Uniswap fees but also crediting as if not collected (double count).
- Partial close updates only position size but not checkpoints, allowing repeated claims.
- Settlement logic assuming ITM netting fully removed residual delta when it did not.

#### Review Intent
- Balance-delta invariant test with a reference ledger model: track ERC20 balances of pool+trackers+users and compare to internal events/checkpoints.

---

### 12. Premium checkpoint / settlement baseline integrity
- Type: invariant
- Priority: critical

#### Statement
- For each owner / tokenId / leg:
  - a newly opened short leg must not inherit premium accrued before its liquidity was added
  - a closed or partially closed leg must not leave remaining liquidity able to claim premium already realized for the exited portion
  - theoretical premia derived from accumulators must never be automatically treated as fully claimable premia unless backed by settled token accounting
- More concretely:
  - `current premium accumulator - stored checkpoint` may determine theoretical premium
  - but `claimable/creditable premium <= settled/available premium backing`
- Post-mint baseline updates must initialize checkpoints forward; post-burn baseline updates must rebase remaining liquidity consistently.

#### Why It Matters
- Panoptic premium accounting is not just fee conservation; it is checkpoint integrity across mint/burn/settle. This is a primary protocol-specific accounting surface.

#### Relevant Mechanisms
- `_getPremia`
- `s_options[owner][tokenId][leg]`
- `_updateSettlementPostMint`
- `_updateSettlementPostBurn`
- settled token pools / available premium logic

#### What Could Break It
- New short liquidity inheriting historical premium accumulator state.
- Partial close not stripping realized premium history from remaining liquidity.
- Treating theoretical premia as immediately claimable without settled token backing.
- Per-leg/per-tokenId checkpoint drift across burn, force exercise, or liquidation.

#### Review Intent
- Stateful tests over mint → settle → partial burn → settle → full burn; assert total premium credited over lifecycle never exceeds accumulator-based entitlement plus settled backing constraints.

---

### 13. Fee growth checkpointing prevents fee sniping and double-claim (per leg, per position)
- Type: invariant
- Priority: critical

#### Statement
- When a position leg is created/increased, its fee/premium checkpoint must be set such that the minter cannot claim any fee growth that accrued before their liquidity was added.
- When a position leg is decreased/closed, the protocol must advance/rebase checkpoints so the remaining open portion cannot later claim fees already realized/credited for the closed portion.
- Across all claim/collect paths (close, liquidate, explicit fee claim if any), the sum of fees credited for a leg over time equals the realizable fee growth for that leg, bounded by Uniswap collectable amounts and internal settlement rules.

#### Why It Matters
- Fee theft is a primary economic risk and has historical precedent with reentrancy/double-collect vectors.

#### Relevant Mechanisms
- `PanopticPool per-leg checkpoints`
- `CollateralTracker.creditFees`
- `Uniswap feeGrowthInside`
- premium/fee accounting layers

#### What Could Break It
- Checkpoint updated after external token transfer/callback, enabling reentrant double-credit.
- Partial close fails to adjust checkpoint proportionally.
- Multiple internal representations of the ‘same’ leg diverge (pool vs tracker source of truth).

#### Review Intent
- Invariant test that repeatedly opens/closes/partial-closes and checks fees credited never exceed Uniswap fees collected plus bounded internal premia.

---

### 14. Position encoding constraints are enforced early (tickSpacing alignment, width bounds, leg count)
- Type: operational_property
- Priority: high

#### Statement
- Any externally supplied position specification must be validated such that:
  - strikes are multiples of tickSpacing
  - widths fall within supported bounds
  - leg count within max
  - ratio/size does not overflow internal numeric types
  - tokenType is consistent with token0/token1 definitions
- Invalid encodings must revert before any external interactions with Uniswap or tokens.

#### Why It Matters
- Invalid encodings can trigger arithmetic overflows/underflows in margin/fee math or create uncloseable positions.

#### Relevant Mechanisms
- `PositionFactory helpers`
- `PanopticPool mint/burn validation`
- type packing/casts

#### What Could Break It
- Unchecked casts to uint128/int128 in position key derivation or liquidity math.
- Validation performed after initiating Uniswap mint, causing stuck callback requirements.

#### Review Intent
- Fuzz position encoding bytes/ints; ensure revert happens early and without changing state.

---

### 15. Force exercise is burn-consistent and economically bounded
- Type: operational_property
- Priority: critical

#### Statement
- If a force exercise succeeds, its execution path must be consistent with the same underlying burn/unwind logic used for ordinary close, except for explicitly defined exercise-specific fees/transfers.
- Exercise must not produce a better economic outcome for the exerciser than an equivalent forced burn/unwind beyond the intended exercise fee schedule.
- Structural exercisability alone must not allow economically unbounded transfer; any value transfer during exercise must be bounded by the same oracle/risk regime used for solvency and close pricing.

#### Why It Matters
- In Panoptic, exercise behaves more like a force-close right than a textbook vanilla option exercise. It therefore needs its own explicit boundedness property.

#### Relevant Mechanisms
- `dispatchFrom`
- `validateIsExercisable`
- `_burnOptions`
- `exerciseCost`
- burn/settlement flows

#### What Could Break It
- Exercise path using weaker oracle assumptions than burn/liquidation.
- Exercise fee sign/rounding allowing net arbitrage.
- Structural exercise admissibility with no meaningful economic bound.

#### Review Intent
- Differential scenario tests comparing burn vs exercise on the same tokenId under the same snapshot; assert all differences are explained only by the explicit exercise fee and allowed force-close semantics.

---

## Liquidation / force-close invariants

### 16. Liquidation eligibility, pricing, and seize are coherent and bounded
- Type: invariant
- Priority: critical

#### Statement
- If liquidation of account `A` succeeds, then at the start of liquidation `A` must be below maintenance margin under the same oracle snapshot used to compute close pricing and seize amount.
- Seized collateral in each token must satisfy:
  - `seizeTokenX <= A.collateralTokenX`
  - `seizeTokenX <= maxSeizeTokenX(computedCloseResult, bonusSchedule, oracleBounds)`
- Liquidation must not create protocol-level deficit: after liquidation, aggregate assets across trackers/pool must still cover aggregate user share claims and explicit liabilities.

#### Why It Matters
- Prevents over-seizure theft and ensures full collateralization is maintained through the backstop mechanism.

#### Relevant Mechanisms
- `PanopticPool.liquidate/forceClose`
- `RiskEngine margin + liquidation incentive math`
- `CollateralTracker debits/transfers`

#### What Could Break It
- Using different prices for eligibility vs seize (spot/TWAP mismatch).
- Rounding that favors liquidator allowing repeated dust extraction.
- Seize computed on notional rather than realized close result.

#### Review Intent
- Scenario + invariant tests: random unhealthy accounts; ensure liquidation improves health and seize is within bounds; verify no negative balances/insolvency in trackers.

---

### 17. Partial liquidation must be health-improving (or revert)
- Type: operational_property
- Priority: high

#### Statement
- For any liquidation that closes only part of a target’s exposure, the target’s health factor (or maintenance shortfall) must improve by at least one unit of protocol health precision after accounting for fees and liquidation bonus; otherwise liquidation should revert or be forced to close more.
- Liquidation must not leave the account in a state where no further liquidation is possible while still under maintenance.

#### Why It Matters
- Prevents griefing where liquidators extract bonus without restoring solvency and prevents bad-debt deadlocks.

#### Relevant Mechanisms
- close factor / maxClose calculations
- rounding in risk + fees
- bonus schedule

#### What Could Break It
- Close-size rounding to zero while still seizing collateral.
- Fees/collect costs exceed benefit, worsening health.

#### Review Intent
- Fuzz partial liquidation params; assert monotone health improvement or revert.

---

## External interaction & callback safety properties (Uniswap + token hooks)

### 18. Uniswap callback authentication and exact owed settlement
- Type: invariant
- Priority: critical

#### Statement
- Any Uniswap callback function must only accept calls from the canonical Uniswap pool/manager bound to this PanopticPool market; all other callers must revert.
- Callback must settle exactly the owed amounts (`amount0Delta/amount1Delta`) and must not transfer any additional tokens to `msg.sender` or arbitrary addresses.
- Callback data decoding must be domain-separated so that a callback intended for one market cannot be replayed against another.

#### Why It Matters
- Prevents direct-callback drains and cross-market confusion/replay, a common exploit class in AMM-integrated protocols.

#### Relevant Mechanisms
- `uniswapV3MintCallback/swapCallback` (or v4 equivalents)
- market binding immutables

#### What Could Break It
- Weak `msg.sender` validation.
- Callback uses user-controlled recipient/spender fields from calldata without validation.
- Missing domain separation for multi-market deployments.

#### Review Intent
- Adversarial tests: call callback directly; attempt replay with data from another pool; assert reverts and no balance changes.

---

### 19. ERC777/hook-token reentrancy cannot double-credit fees or bypass margin checks
- Type: scenario_hypothesis
- Priority: critical

#### Statement
- Assume underlying token0 or token1 is ERC777-like (or ERC20 with hooks) and reenters on transfer/transferFrom during:
  - `CollateralTracker.deposit/withdraw`
  - `PanopticPool mint/burn/exercise/liquidation`
  - Uniswap callback payment
  - fee/premium crediting/collection
- Under all such reentrancy, attacker cannot:
  - claim the same feeGrowth/premia twice
  - withdraw more than allowed by maintenance
  - manipulate checkpoints mid-transition to steal shared fees
- Any reentrant call observing intermediate state must either revert or see a state consistent with already advanced checkpoints and already debited balances.

#### Why It Matters
- Historical Panoptic-family issues include fee theft via ERC777 reentrancy; this is a high-value regression anchor.

#### Relevant Mechanisms
- `nonReentrant guards across pool+trackers`
- `check-effects-interactions ordering`
- fee/premium checkpoint updates

#### What Could Break It
- Checkpoint updates performed after token transfer/collect.
- Guard applied only on one contract; cross-contract reentry bypasses it.
- A view health check used for gating but reentrancy changes state after the check.

#### Review Intent
- Exploit-style harness with ERC777 mock token: attempt reentrant double-collect and withdrawal during mint/burn/liquidation/exercise.