# Invariants

This review should separate:

- general / cross-market invariants
- mature-market invariants, where accounting has meaningful depth and liquidity
- empty / tiny / newly-created market invariants, where virtual shares, first-user effects, and low-liquidity pathologies dominate

Reviewer stance:
- virtual shares / virtual assets are a mitigation, not a full defense
- they can improve some zero-state edge cases
- they do not eliminate fresh-market and low-liquidity manipulation
- they mainly change the scale and geometry of the attack surface
- in some paths, they may themselves create or amplify accounting distortion

## 1. Market identity must stay consistent with the accounting bucket being mutated

### Statement
Every state transition for a market assumes the provided `MarketParams` resolves to the same `id` whose storage is being read and written. The tuple `{loanToken, collateralToken, oracle, irm, lltv}` must remain the canonical identity of that market.

### Why It Matters
Morpho keys all core accounting off `marketParams.id()`. If execution ever mixes one market’s storage with another market’s dependencies, then interest accrual, health checks, token transfers, and liquidation math can all run against the wrong assumptions.

### Relevant Mechanisms
- `marketParams.id()`
- `market[id]`
- `position[id][user]`
- `idToMarketParams[id]`
- every public market action in `Morpho.sol`

### What Could Break It
- mutating state under an `id` derived from mismatched market parameters
- relying on caller-supplied `marketParams` after market creation without preserving canonical identity assumptions
- any bug that lets one market reuse another market’s oracle / token / IRM assumptions

---

**Mature Markets**

## 2. Supply-side accounting must remain coherent across user actions, interest accrual, fees, and bad debt

### Statement
`totalSupplyShares` should only change through supplier mint/burn flows and fee-share minting, while `totalSupplyAssets` should move coherently with deposits, withdrawals, accrued interest, and bad-debt socialization.

### Why It Matters
Suppliers hold claims through shares, but solvency is tracked through assets. Morpho intentionally allows `totalSupplyAssets` to move without all user balances moving one-by-one, so the review has to verify that every such move is an intended repricing rather than accounting drift.

### Relevant Mechanisms
- `supply()`
- `withdraw()`
- `_accrueInterest()`
- `setFee()`
- `liquidate()`
- `position[id][user].supplyShares`
- `market[id].totalSupplyAssets`
- `market[id].totalSupplyShares`

### What Could Break It
- updating user supply shares without updating market supply shares, or the reverse
- fee-share minting that dilutes suppliers by more than the configured fee logic implies
- bad-debt cleanup reducing `totalSupplyAssets` incorrectly
- non-standard token behavior causing actual token balances to diverge from recorded supply assets
- virtual supply shares participating in repricing in a way that leaks value away from real suppliers

---

## 3. A supplier should not receive new supply shares except through explicit supply or fee-share minting

### Statement
For an ordinary user, `position[id][user].supplyShares` should only increase when that user supplies assets or shares on purpose. The only protocol-driven share minting during interest accrual should be the fee-share mint to `feeRecipient`.

### Why It Matters
Accrued interest is distributed implicitly by increasing `totalSupplyAssets`, not by minting fresh shares to every supplier. If arbitrary users can receive extra shares during accrual, they can capture value that should instead flow through share price appreciation.

### Relevant Mechanisms
- `supply()`
- `_accrueInterest()`
- `position[id][user].supplyShares`
- `position[id][feeRecipient].supplyShares`
- `market[id].totalSupplyShares`

### What Could Break It
- accidental user-level share minting during interest accrual
- fee-share minting credited to the wrong address
- callback or reentrancy paths that create duplicate supply-share increases
- future code changes that try to "distribute" interest by mutating user shares directly

---

## 4. Total supply shares and total supply assets should move through intended repricing rules, not drift independently

### Statement
`totalSupplyShares` and `totalSupplyAssets` do not need to move one-for-one, but every divergence between them must be explainable by a specific mechanism:

- deposits and withdrawals change both
- accrued interest changes assets without changing ordinary user shares
- fee crystallization changes shares without adding new external assets
- bad debt reduces supply assets without burning supplier shares

### Why It Matters
This is the correct Morpho version of “share supply and asset supply should trace each other.” The two variables are allowed to diverge, but only for explicit repricing reasons. Unexplained divergence is an accounting bug.

### Relevant Mechanisms
- `supply()`
- `withdraw()`
- `_accrueInterest()`
- fee-share minting in `_accrueInterest()`
- bad-debt cleanup in `liquidate()`
- `market[id].totalSupplyAssets`
- `market[id].totalSupplyShares`

### What Could Break It
- updating only one of the two totals on a supply-side state transition
- fee minting against the wrong accounting base
- bad-debt socialization reducing assets by too much or too little
- token-transfer assumptions causing recorded supply assets to stop matching intended economic backing

---

## 5. Borrow-side accounting must remain coherent across borrow, repay, accrual, liquidation, and bad-debt cleanup

### Statement
`totalBorrowShares` should track the aggregate of user debt shares, while `totalBorrowAssets` should evolve only through borrowing, repayment, accrued interest, liquidation repayment, and explicit bad-debt removal.

### Why It Matters
Borrowers owe debt in shares, but health checks and liquidation settle in assets. If the asset/share relationship drifts unexpectedly, borrowers may be overcharged, undercharged, or liquidated incorrectly.

### Relevant Mechanisms
- `borrow()`
- `repay()`
- `_accrueInterest()`
- `liquidate()`
- `position[id][user].borrowShares`
- `market[id].totalBorrowAssets`
- `market[id].totalBorrowShares`
- `UtilsLib.zeroFloorSub`

### What Could Break It
- failing to mirror user borrow-share changes into market borrow-share totals
- incorrect rounding when converting between debt assets and debt shares
- over-removing borrow assets during repay or liquidation
- residual borrower debt not being cleaned up correctly when collateral is exhausted
- virtual borrow shares participating in debt growth in a way that creates ghost debt or withdrawability loss

---

## 6. Virtual supply shares should not absorb a disproportionate share of interest that ought to accrue to real suppliers

### Statement
The virtual supply-share component used to stabilize conversion math should not capture an economically material portion of interest growth relative to real supplier positions, especially once the market has non-trivial supply.

### Why It Matters
If unowned virtual supply shares participate too strongly in share repricing, then supplier-side accounting can look internally consistent while still leaking value away from real LPs.

### Relevant Mechanisms
- `SharesMathLib`
- `market[id].totalSupplyAssets`
- `market[id].totalSupplyShares`
- `_accrueInterest()`
- supply share to asset conversion paths

### What Could Break It
- virtual supply shares taking a persistent slice of interest growth
- low-liquidity states where virtual balances dominate repricing
- supplier returns that lag recorded market growth for reasons not explained by fees or bad debt

---

## 7. Virtual borrow shares should not create economically unowned debt that degrades withdrawability

### Statement
The virtual borrow-share component used to stabilize conversion math should not accumulate into economically meaningful debt that no real borrower can clear, especially after liquidations or in low-borrow markets.

### Why It Matters
If virtual borrow shares accrue debt but are owned by no user, the market can end up with ghost debt: recorded borrow-side obligations that still reduce withdrawable funds even though no one can repay them directly.

### Relevant Mechanisms
- `SharesMathLib`
- `market[id].totalBorrowAssets`
- `market[id].totalBorrowShares`
- `_accrueInterest()`
- `liquidate()`
- bad-debt cleanup paths

### What Could Break It
- debt growth tied to virtual borrow shares in tiny markets
- liquidation or repay flows that leave behind unowned residual borrow assets
- fresh-market precision states that turn virtual balances into practical bad debt

---

## 8. Accrued interest alone can make a borrower liquidatable, but only through the intended debt-growth path

### Statement
A borrower who was healthy at time `t0` may become liquidatable at time `t1` solely because interest accrued and increased the asset value of their fixed `borrowShares`. If that happens, the liquidation should be attributable to debt growth from `_accrueInterest()`, not to any hidden mutation of collateral or borrow shares.

### Why It Matters
This is an intended economic property of overcollateralized lending with lazy accrual. It should be explicit in the review because it creates real path dependence: a borrower can become unsafe without taking any new action, simply because time passed and debt accrued.

### Relevant Mechanisms
- `_accrueInterest()`
- `market[id].totalBorrowAssets`
- `position[id][borrower].borrowShares`
- `_isHealthy()`
- `liquidate()`
- `IOracle.price()`

### What Could Break It
- debt growth being applied inconsistently across borrowers
- hidden user-level share mutations during accrual
- stale accrual letting a liquidation use old debt while a later action uses new debt
- liquidation eligibility changing for reasons other than accrued debt or oracle price movement

---

## 9. Recorded market accounting should not end a successful loan-side action with `totalBorrowAssets > totalSupplyAssets`

### Statement
At the level of Morpho’s recorded market totals, a successful loan-side action should not leave `market[id].totalBorrowAssets > market[id].totalSupplyAssets`.

This is a statement about stored accounting, not a full statement about real-world solvency against non-standard tokens, oracle failure, or realizable collateral value under stress.

### Why It Matters
This is Morpho’s direct on-chain liquidity bound for recorded market state. `borrow()` and `withdraw()` enforce it explicitly, while `repay()`, `_accrueInterest()`, and `liquidate()` should preserve it by construction if it already held beforehand.

### Relevant Mechanisms
- `createMarket()`
- `borrow()`
- `withdraw()`
- `repay()`
- `_accrueInterest()`
- `liquidate()`
- bad-debt handling in `liquidate()`

### What Could Break It
- missing or misordered liquidity checks
- a path that mutates `totalBorrowAssets` without the corresponding bound check or monotone-preserving update
- bad-debt cleanup that reduces borrow assets and supply assets inconsistently
- edge cases where rounding lets assets leave while recorded supply is insufficient
- future code changes that introduce a new loan-side mutation path without preserving the invariant

---

## 10. A successful borrow or collateral withdrawal must leave the account healthy at the current accrued debt and oracle price

### Statement
If `borrow()` or `withdrawCollateral()` succeeds, the affected `onBehalf` position must satisfy Morpho’s health check immediately after the state update.

### Why It Matters
This is the borrower-side safety boundary. Morpho allows users to approach the LLTV limit, but not cross it on a successful self-directed debt increase or collateral decrease.

### Relevant Mechanisms
- `borrow()`
- `withdrawCollateral()`
- `_accrueInterest()`
- `_isHealthy()`
- `IOracle.price()`
- `marketParams.lltv`

### What Could Break It
- stale or manipulated oracle values
- incorrect debt-share to asset conversion
- missing accrual before health evaluation
- rounding in the wrong direction, allowing slightly unsafe positions to pass

---

## 11. Liquidation must only apply to unhealthy positions and must exchange collateral for debt reduction coherently

### Statement
A liquidation should only succeed when the borrower is unhealthy, and the chosen liquidation path must produce a coherent pairing between seized collateral, repaid debt shares, repaid debt assets, and any residual bad debt.

### Why It Matters
Liquidation is the protocol’s forced-settlement path. If it can trigger on healthy accounts, seize too much collateral, or fail to reduce debt consistently, it becomes a direct theft or insolvency vector.

### Relevant Mechanisms
- `liquidate()`
- `_isHealthy()`
- oracle price lookup
- liquidation incentive math
- both caller-controlled branches:
  - `seizedAssets` input
  - `repaidShares` input

### What Could Break It
- incorrect liquidation incentive calculation
- wrong rounding direction between collateral value and debt value
- branch-specific mismatch between quoted collateral and repaid shares
- partial cleanup that transfers collateral out without the corresponding debt settlement

---

## 12. Liquidation incentive configuration should remain bounded and monotone across enabled LLTVs

### Statement
For any enabled `lltv`, the computed liquidation incentive factor should remain economically sane and within the protocol’s intended bounds. The factor should follow the implemented formula consistently, remain monotonic across `lltv` choices, and never exceed `MAX_LIQUIDATION_INCENTIVE_FACTOR`.

Under Morpho's implemented formula, the factor is non-increasing as `lltv` rises.

### Why It Matters
Liquidation incentives are the bridge between solvency protection and borrower fairness. If the factor is too low, liquidations may not be profitable enough to clear risk. If it is too high, liquidators can seize disproportionate collateral and create unnecessary borrower loss.

### Relevant Mechanisms
- `liquidate()`
- `marketParams.lltv`
- `LIQUIDATION_CURSOR`
- `MAX_LIQUIDATION_INCENTIVE_FACTOR`
- `liquidationIncentiveFactor = min(MAX_LIQUIDATION_INCENTIVE_FACTOR, 1 / (1 - cursor * (1 - lltv)))`

### What Could Break It
- an LLTV configuration that produces unintuitive or extreme incentives near protocol limits
- incorrect fixed-point math in the incentive formula
- loss of monotonicity relative to the protocol’s implemented formula
- a cap or formula bug that allows excessive collateral seizure

---

## 13. If a borrower’s collateral is fully exhausted, residual debt must be recognized explicitly as bad debt

### Statement
When liquidation drives a borrower’s collateral to zero, any remaining debt must not linger as a collectible healthy claim. It must be converted into explicit bad debt by reducing market borrow assets, market supply assets, market borrow shares, and the borrower’s remaining borrow shares coherently.

### Why It Matters
This is Morpho’s insolvency crystallization path. If exhausted positions keep residual borrow shares without backing collateral, the market can become internally inconsistent and suppliers can face hidden losses rather than explicit accounting.

### Relevant Mechanisms
- `liquidate()`
- `position[id][borrower].collateral`
- `position[id][borrower].borrowShares`
- `market[id].totalBorrowAssets`
- `market[id].totalSupplyAssets`
- `market[id].totalBorrowShares`

### What Could Break It
- failing to zero borrower debt shares after collateral exhaustion
- subtracting the wrong bad-debt asset amount from supply or borrow totals
- allowing bad debt to exceed remaining market borrow assets
- rounding that leaves dust debt in a way the market no longer accounts for coherently

---

**Empty / Tiny / Newly-Created Markets**

## 14. The first borrower in a fresh market must not be able to inflate borrow shares enough to grief future borrowing

### Statement
In an empty or near-empty market, the first borrower should not be able to manipulate `totalBorrowShares` and the borrow-share price so aggressively that later honest borrowing becomes impractical, unexpectedly expensive, or reverts.

### Why It Matters
Morpho's virtual-share design improves some empty-market behavior, but it does not eliminate first-user precision distortions. Fresh markets are still the highest-risk zone for borrow-share inflation and borrowing grief.

### Relevant Mechanisms
- `borrow()`
- `repay()`
- `market[id].totalBorrowAssets`
- `market[id].totalBorrowShares`
- `SharesMathLib`
- virtual shares / virtual assets assumptions

### What Could Break It
- extreme borrow-share inflation from tiny initial borrows
- low-debt markets where rounding dominates economics
- a first-borrower sequence that makes subsequent borrows overflow, round pathologically, or revert unexpectedly
- any griefing path that relies on fresh-market precision rather than real economic exposure

---

## 15. Low-liquidity markets should not allow tiny actions to create disproportionate share-price distortion

### Statement
When market totals are still tiny, deposits, withdrawals, borrows, repays, donations, and liquidations should not let an attacker create a disproportionate jump in effective supply-share or borrow-share pricing relative to the capital actually committed.

### Why It Matters
In mature markets, small rounding losses are usually harmless. In tiny markets, the same mechanics can dominate the state and create pricing that is manipulable, misleading, or hostile to the next participant. Virtual shares change the shape of this problem, but do not remove it.

### Relevant Mechanisms
- `supply()`
- `withdraw()`
- `borrow()`
- `repay()`
- `liquidate()`
- `SharesMathLib`
- `market[id].totalSupplyAssets`
- `market[id].totalSupplyShares`
- `market[id].totalBorrowAssets`
- `market[id].totalBorrowShares`

### What Could Break It
- dust-scale actions causing outsized jumps in implied share price
- low-liquidity liquidation or repay paths that reprice the market discontinuously
- donation-like balance changes or liquidity starvation around tiny totals
- path dependence that disappears once the market is larger, indicating fresh-market-only fragility

---

## 16. Stateful IRMs should not be pushable into pathological rate regimes by dust-scale low-liquidity manipulation alone

### Statement
If an enabled IRM is stateful or highly utilization-sensitive, a low-liquidity attacker should not be able to move a new or tiny market into a pathological borrow-rate regime merely through dust borrowing, dust repayment, or tiny liquidity shifts.

### Why It Matters
Morpho market creation is permissionless once dependencies are enabled. That means fresh markets inherit all the fragility of their IRM at exactly the moment when accounting depth is weakest and utilization is easiest to manipulate. Virtual shares are not a general defense against this class of low-liquidity IRM pathology.

### Relevant Mechanisms
- `createMarket()`
- `_accrueInterest()`
- `IIrm.borrowRate()`
- `borrow()`
- `repay()`
- `withdraw()`
- market utilization in tiny states

### What Could Break It
- stateful IRM initialization that reacts badly to near-zero totals
- low-liquidity utilization spikes driving pathological rates
- attacker-controlled tiny actions creating liveness or overflow pressure through IRM outputs
- fresh-market states that are economically meaningless but still feed dangerous values into accrual

---

## 17. Lazy accrual should remain economically coherent across irregular update cadence, especially with stateful IRMs

### Statement
Accruing interest through many small `_accrueInterest()` steps versus fewer larger steps should not create pathological divergence beyond the protocol's intended approximation and fee mechanics. This is especially important when the IRM is stateful.

### Why It Matters
In Morpho Blue, lazy accrual is a protocol-level economic boundary, not just a gas optimization. `_accrueInterest()` is where debt growth, supplier-side asset growth, fee dilution, and IRM state sampling are all crystallized. If cadence sensitivity is excessive, users can experience meaningfully different economics depending only on when accrual happened.

### Relevant Mechanisms
- `_accrueInterest()`
- `IIrm.borrowRate()`
- `market[id].totalBorrowAssets`
- `market[id].totalSupplyAssets`
- `market[id].fee`
- any stateful IRM internal state transitions

### What Could Break It
- zero-borrow edge cases that skip or desynchronize stateful IRM updates
- many small accrual calls producing meaningfully different outcomes than one large accrual call
- stateful IRMs whose internal transitions assume a different accrual cadence than Morpho provides
- cadence-dependent fee dilution or borrow growth beyond intended approximation error

---

## 18. Rounding direction must consistently favor protocol safety on supply/withdraw and borrow/repay paths

### Statement
Conversions between assets and shares should preserve Morpho’s intended conservative bias:

- supply uses `toSharesDown` / `toAssetsUp`
- withdraw uses `toSharesUp` / `toAssetsDown`
- borrow uses `toSharesUp` / `toAssetsDown`
- repay uses `toSharesDown` / `toAssetsUp`

### Why It Matters
This rounding policy is part of the protocol’s safety model. If even one path rounds the wrong way, users may mint excess claims, repay too little debt, withdraw too much liquidity, or borrow more than their collateral should permit.

### Relevant Mechanisms
- `SharesMathLib`
- `supply()`
- `withdraw()`
- `borrow()`
- `repay()`
- `liquidate()`
- `_isHealthy()`

### What Could Break It
- using the wrong conversion helper on a single path
- mismatching previewed intent with executed conversion direction
- tiny-market edge cases around virtual shares / virtual assets
- liquidation math composing otherwise-correct rounding helpers in the wrong order

---

## 19. Callback-based flows must be safe only because failure rolls back the full transaction

### Statement
For `supply`, `repay`, `supplyCollateral`, `liquidate`, and `flashLoan`, any intermediate state updates or outbound transfers that happen before the final payment pull must be safe only under full atomic rollback semantics. No successful transaction should leave partially paid or partially reverted accounting behind.

### Why It Matters
Morpho intentionally performs some accounting updates before callbacks and before the final `transferFrom`. This is acceptable only if every failure path reverts the entire transaction and there is no reentrancy window that can successfully preserve inconsistent intermediate state.

### Relevant Mechanisms
- `supply()`
- `repay()`
- `supplyCollateral()`
- `liquidate()`
- `flashLoan()`
- the various `onMorpho...` callbacks
- final `safeTransferFrom` payment pulls

### What Could Break It
- non-standard token behavior or callback reentrancy assumptions
- a code path that catches failure instead of reverting
- external calls observing and exploiting intermediate state before final payment
- any future integration that assumes the pre-transfer state is final

---

## 20. Fee crystallization must apply only to accrued interest and must not rewrite principal accounting

### Statement
Fee extraction should happen only through fee-share minting during `_accrueInterest()`, using the interest that has accrued since the previous checkpoint. Changing the fee should not retroactively apply a new fee rate to already-unaccrued history.

### Why It Matters
Morpho charges fees by minting supply shares, which dilutes suppliers rather than moving principal directly. This is economically sensitive and timing-sensitive, especially because accrual is lazy.

### Relevant Mechanisms
- `_accrueInterest()`
- `setFee()`
- `market[id].fee`
- `feeRecipient`
- `position[id][feeRecipient].supplyShares`
- `market[id].totalSupplyShares`

### What Could Break It
- minting fee shares from principal instead of interest
- calculating fee shares against the wrong supply base
- updating the fee before crystallizing old-period interest
- repeated accrual patterns producing unintended over-dilution

---

## 21. Delegation and signature-based authorization must not allow replay or overreach beyond the intended account

### Statement
Only the account owner or an explicitly authorized operator should be able to manage a user’s withdraw, borrow, and collateral-removal flows. Signature-based authorization must consume the correct nonce exactly once and respect the deadline.

### Why It Matters
Morpho supports delegated position management. If this authority model is weak, an attacker can borrow, withdraw, or strip collateral from another user without touching the lending math itself.

### Relevant Mechanisms
- `_isSenderAuthorized()`
- `setAuthorization()`
- `setAuthorizationWithSig()`
- `nonce[authorizer]`
- EIP-712 digest recovery

### What Could Break It
- nonce misuse or replay
- signer recovery accepting malformed signatures
- missing authorization checks on a management path
- accidental authority over the wrong `onBehalf` account

---

## 22. Flash loans should be accounting-neutral to Morpho’s market state apart from temporary token movement

### Statement
`flashLoan()` should not mutate market accounting, user positions, authorization state, or fee state. Its only intended effect is a temporary token transfer that is reversed before the transaction completes.

### Why It Matters
Flash loans deliberately give the caller arbitrary one-transaction control flow. The review question is therefore whether that control flow can leak into persistent Morpho accounting rather than remaining a transient liquidity primitive.

### Relevant Mechanisms
- `flashLoan()`
- `onMorphoFlashLoan()`
- token `safeTransfer` / `safeTransferFrom`

### What Could Break It
- reentrancy into accounting-sensitive paths that assume no active flash-loan context
- non-standard token behavior that prevents exact repayment semantics
- future code changes that couple flash loans to fee, share, or authorization state
