# Issue Candidates

## Candidate 1: Bad-debt socialization can be delayed by leaving exactly `1 wei` collateral
### Category
Liquidation / bad-debt realization / loss-distribution path dependence

### Observation
`liquidate()` only crystallizes residual bad debt when `position[id][borrower].collateral == 0`.

That means a liquidator can intentionally:
- perform a partial liquidation
- leave exactly `1 wei` collateral
- keep residual debt unsocialized for one more step
- allow suppliers to exit in between
- then finish the liquidation and socialize the remaining bad debt onto whoever is still in the market

### Why It Matters
This turns bad-debt realization into a sequencing game. Losses are not necessarily borne by the supplier set that funded the position through the whole lifecycle; they can be shifted onto the remaining LP set at the final crystallization step.

### Potential Impact
- early-exiting suppliers avoid losses
- remaining suppliers absorb a disproportionate share of bad debt
- liquidation sequencing becomes economically adversarial rather than neutral

### Related Invariants
- If a borrower’s collateral is fully exhausted, residual debt must be recognized explicitly as bad debt.
- Recorded market accounting should not end a successful loan-side action with `totalBorrowAssets > totalSupplyAssets`.
- Liquidation must only apply to unhealthy positions and must exchange collateral for debt reduction coherently.

### Related Tests
- `test_Review_BadDebtSocializationCanBeDelayedByLeavingOneWeiCollateral`

### Status
Strong candidate.  
This is directly supported by the review characterization test and aligns with external audit findings about delayed bad-debt realization.

### How I Would Validate It
- create a market with multiple suppliers
- partially liquidate an unhealthy borrower while leaving `1 wei` collateral
- let one supplier exit
- finish liquidation
- compare who absorbs the final bad-debt hit

---

## Candidate 2: Virtual supply shares may absorb part of interest growth that real suppliers expected to receive
### Category
Accounting / economic dilution / virtual-balance side effect

### Observation
Morpho's virtual supply shares participate in share conversion math even though they are not owned by a real supplier.

In tiny markets, the review test shows that:
- `market[id].totalSupplyAssets` grows after accrual
- but a real supplier’s asset claim can grow by less than total market growth
- even when no protocol fee is configured

### Why It Matters
Supplier-side accounting can remain internally coherent while still leaking economic value away from real LPs. This is not fee dilution; it is a side effect of how virtual balances participate in repricing.

### Potential Impact
- real suppliers earn less than the naive interest-growth expectation
- the effect is strongest in tiny / fresh markets
- integrators may misread supplier APR if they ignore virtual-balance leakage

### Related Invariants
- Supply-side accounting must remain coherent across user actions, interest accrual, fees, and bad debt.
- Virtual supply shares should not absorb a disproportionate share of interest that ought to accrue to real suppliers.
- Total supply shares and total supply assets should move through intended repricing rules, not drift independently.

### Related Tests
- `test_Review_VirtualSupplySharesCanLeavePartOfInterestOutsideRealSupplierClaim`

### Status
Strong characterization candidate.  
Needs careful severity judgment because the effect may be economically small in mature markets but materially relevant in tiny markets.

### How I Would Validate It
- build a tiny market with one real supplier and no fee
- accrue interest
- compare market-level asset growth to the real supplier’s claim growth
- measure how the gap changes as market size grows

---

## Candidate 3: Virtual borrow shares may leave residual recorded debt that reduces supplier withdrawability
### Category
Accounting / withdrawability / virtual-balance side effect

### Observation
Virtual borrow shares participate in borrow-side conversion math even though no user owns them.

The review characterization test shows a path where:
- the real borrower repays all owned `borrowShares`
- the borrower position reaches zero borrow shares
- but the market can still retain recorded borrow assets
- and that residual debt can constrain full supplier withdrawal

### Why It Matters
This creates a form of ghost debt: recorded market liabilities that are no longer cleanly attributable to a real borrower position but still affect liquidity and exitability for suppliers.

### Potential Impact
- suppliers may be unable to fully withdraw despite the borrower clearing all owned shares
- tiny markets can accumulate practically unowned residual debt
- withdrawability and market solvency become harder to reason about from user positions alone

### Related Invariants
- Borrow-side accounting must remain coherent across borrow, repay, accrual, liquidation, and bad-debt cleanup.
- Virtual borrow shares should not create economically unowned debt that degrades withdrawability.
- Recorded market accounting should not end a successful loan-side action with `totalBorrowAssets > totalSupplyAssets`.

### Related Tests
- `test_Review_VirtualBorrowSharesCanLeaveResidualDebtThatReducesWithdrawability`

### Status
Strong characterization candidate.  
Likely most relevant in fresh / tiny markets rather than deep markets.

### How I Would Validate It
- create a tiny borrow position
- repay all owned borrow shares
- inspect `market[id].totalBorrowAssets`
- attempt full supplier withdrawal and observe whether residual debt blocks it

---

## Candidate 4: Tiny partial liquidations may create unfair or path-dependent outcomes through rounding
### Category
Liquidation rounding / borrower fairness / low-liquidity precision

### Observation
Liquidation supports two caller-controlled entry branches:
- specify `seizedAssets`
- specify `repaidShares`

External audit findings and the review tests suggest that tiny liquidation amounts are a real attack surface, not just a nuisance:
- dust liquidations can create path dependence
- `seizedAssets` rounding can change collateral and debt asymmetrically
- `repaidShares` rounding needs special care to ensure collateral is never seized for zero effective debt reduction

### Why It Matters
Liquidation can be formally valid while still being economically distorted. Repeated dust liquidations may strip collateral or worsen a borrower’s effective position more than intuitive debt reduction would suggest.

### Potential Impact
- borrowers lose collateral through repeated dust liquidations
- health can worsen or improve less than expected after partial liquidation
- branch-specific rounding behavior creates exploitable asymmetry

### Related Invariants
- Liquidation must only apply to unhealthy positions and must exchange collateral for debt reduction coherently.
- Rounding direction must consistently favor protocol safety on supply/withdraw and borrow/repay paths.
- If a borrower’s collateral is fully exhausted, residual debt must be recognized explicitly as bad debt.

### Related Tests
- `test_Review_TinyLiquidation_SeizedAssetsBranch_DoesNotWorsenBorrowerHealthPerUnitDebtReduction`
- `test_Review_TinyLiquidation_RepaidSharesBranch_CannotSeizeCollateralForZeroDebtReduction`
- `test_Review_RepeatedDustLiquidations_CannotStripCollateralWhileBarelyReducingDebt`
- `test_Review_LiquidationMustNotSocializePhantomBadDebtWhenResidualBorrowSharesAreZero`

### Status
Strong candidate.  
Supported by external audit findings; current review tests give characterization coverage but not yet a full exploit proof for every branch.

### How I Would Validate It
- run repeated dust liquidations in both branches
- compare collateral lost versus debt actually reduced
- check borrower health after each partial liquidation
- search for cases where collateral moves while effective debt relief is negligible

---

## Candidate 5: First-borrower borrow-share inflation can grief later users in fresh / tiny markets
### Category
Fresh-market griefing / share inflation / liveness degradation

### Observation
External findings indicate that in very small borrow markets, the first borrower can inflate `totalBorrowShares` enough to make later borrowing impractical or revert unexpectedly.

Morpho acknowledges this risk is concentrated in markets with very low borrowed assets rather than eliminated by virtual balances.

### Why It Matters
This creates a distinct fresh-market risk regime. A market may be permissionlessly creatable, yet effectively griefable before it reaches meaningful liquidity depth.

### Potential Impact
- later borrowers face distorted share pricing
- future borrowing can become unexpectedly expensive or impossible
- fresh-market UX and liveness degrade even when the market is otherwise valid

### Related Invariants
- The first borrower in a fresh market must not be able to inflate borrow shares enough to grief future borrowing.
- Low-liquidity markets should not allow tiny actions to create disproportionate share-price distortion.
- Virtual borrow shares should not create economically unowned debt that degrades withdrawability.

### Related Tests
- No dedicated test yet.

### Status
Known issue class / literature-backed candidate, but not yet directly reproduced in the local review test suite.  
Keep as a targeted review lead until a dedicated fresh-market griefing test is added.

### How I Would Validate It
- create a fresh market
- perform tiny first-borrower sequences
- compare share state before and after
- test whether later honest borrowing becomes pathologically expensive or reverts

---

## Candidate 6: Low-liquidity supply share-price manipulation can make later suppliers overpay
### Category
Fresh-market manipulation / entry fairness / share pricing

### Observation
External competition findings indicate that low-liquidity markets can still be manipulated so that later suppliers receive meaningfully worse entry pricing, even with virtual shares in place.

### Why It Matters
Virtual shares do not fully solve early-market entry fairness. They change the attack geometry, but low-liquidity markets can still be manipulated so that later suppliers over-contribute relative to shares received.

### Potential Impact
- late suppliers receive too few shares per asset
- attacker-created low-liquidity conditions distort entry pricing
- integrators may misprice entry in markets that have not matured

### Related Invariants
- Low-liquidity markets should not allow tiny actions to create disproportionate share-price distortion.
- Virtual supply shares should not absorb a disproportionate share of interest that ought to accrue to real suppliers.
- Total supply shares and total supply assets should move through intended repricing rules, not drift independently.

### Related Tests
- `test_Review_VirtualSupplySharesCanLeavePartOfInterestOutsideRealSupplierClaim`
- `test_Review_RoundingPolicy_FavorsProtocolOnSupplyWithdrawAndBorrowRepay`
- `test_Review_USDCLikeSixDecimalLoanToken_HealthLiquidationAndRoundingRemainCoherent`

### Status
Reasonable candidate / review lead, but current local tests only provide supporting characterization rather than a direct manipulated-entry proof of concept.  
Should be upgraded only after adding a dedicated manipulated-entry test.

### How I Would Validate It
- create a fresh market with tiny liquidity
- manipulate share state using small actions
- compare shares received by a later honest supplier before and after manipulation

---

## Candidate 7: Lazy accrual plus stateful IRMs is a protocol-level compatibility and path-dependence surface
### Category
IRM integration / lazy settlement / economic path dependence

### Observation
Morpho samples IRM behavior only when `_accrueInterest()` runs. For stateful or cadence-sensitive IRMs, this means:
- zero-borrow states matter
- irregular accrual cadence matters
- many small accrual steps can differ from one large accrual step

This is not merely a gas optimization detail; it is an accounting and integration boundary.

### Why It Matters
If the IRM assumes different state transitions than Morpho actually provides, borrow growth, fee dilution, and supplier-side growth can all become cadence-sensitive or economically inconsistent.

### Potential Impact
- stateful IRMs behave incorrectly in zero-borrow or tiny-market states
- debt growth differs materially across accrual cadence
- liveness or overflow pressure appears under pathological rate outputs

### Related Invariants
- Lazy accrual should remain economically coherent across irregular update cadence, especially with stateful IRMs.
- Stateful IRMs should not be pushable into pathological rate regimes by dust-scale low-liquidity manipulation alone.
- Fee crystallization must apply only to accrued interest and must not rewrite principal accounting.

### Related Tests
- `test_Review_AccrualIncreasesAssetsButDoesNotMintSupplierShares`
- `test_Review_AccruedInterestAloneCanMakeBorrowerLiquidatable`

### Status
Design/integration review theme, not a near-term exploit claim by itself.  
May become a concrete issue only when paired with a specific stateful IRM behavior, cadence-sensitive divergence, or zero-borrow incompatibility.

### How I Would Validate It
- compare one large accrual step versus many smaller steps
- test zero-borrow and near-zero-borrow states with a stateful IRM
- inspect whether borrow growth, fees, and market totals diverge materially
