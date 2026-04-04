# Final Review

## Protocol Summary
`Morpho Blue` is a singleton lending protocol where each market is keyed by a `MarketParams` tuple:
- `loanToken`
- `collateralToken`
- `oracle`
- `irm`
- `lltv`

Accounting is stored at two layers:
- market-level state in `market[id]`
- user-level state in `position[id][user]`

Supply and borrow positions are tracked in shares, while collateral is tracked in token amount. Interest is accrued lazily rather than continuously, and many core economic effects are only crystallized when `_accrueInterest()` is reached.

## In-Scope Files

### Core Contract
- `evm-playground/src/review/Morpho.sol`

### Supporting Interfaces / Libraries
- `evm-playground/src/review/interfaces/IMorpho.sol`
- `evm-playground/src/review/interfaces/IIrm.sol`
- `evm-playground/src/review/interfaces/IOracle.sol`
- `evm-playground/src/review/libraries/SharesMathLib.sol`
- `evm-playground/src/review/libraries/MarketParamsLib.sol`
- `evm-playground/src/review/libraries/ConstantsLib.sol`

## Review Approach
This review focused on:
- manual review of market-level and user-level accounting transitions
- review of supply / borrow share math and directional rounding
- review of liquidation, bad-debt realization, and low-liquidity edge cases
- review of lazy accrual as the main accounting crystallization path
- review of virtual share / virtual asset side effects
- review of authorization and callback control-flow surfaces
- targeted Foundry review tests derived from the invariants and issue candidates

The current review test suite for Morpho Blue includes 21 targeted tests covering:
- accounting coherence under accrual
- liquidation eligibility and dust-liquidation behavior
- delayed bad-debt realization
- virtual-balance characterization
- authorization and signature paths
- callback rollback assumptions
- mixed-decimal token behavior

## Main Attack Surfaces
- lazy interest accrual and fee crystallization
- oracle-valued health checks
- liquidation branch choice and rounding
- bad-debt realization timing
- virtual share / virtual asset participation in repricing
- low-liquidity and fresh-market share-state behavior
- stateful IRM compatibility and cadence sensitivity
- delegated position management and EIP-712 authorization
- callback-enabled state transitions

## Core Conclusions

### 1. Core accounting appears coherent, but fresh markets behave differently from mature markets
At the level of recorded market accounting, the main supply / borrow / repay / withdraw / liquidation flows are internally coherent under Morpho’s intended token, oracle, and IRM assumptions.

However, the review strongly suggests that fresh and tiny markets must be treated as their own risk regime. Virtual balances regularize some empty-market behavior, but they do not eliminate:
- first-user share-state distortion
- low-liquidity price / share manipulation
- fresh-market borrow-share inflation
- tiny-market residual debt and withdrawability edge cases

The practical review implication is that “works in mature markets” is not enough. Morpho Blue needs a separate fresh-market mental model.

---

### 2. Bad-debt realization timing is an allocation boundary
Morpho only crystallizes residual bad debt when a borrower’s collateral reaches zero.

That is not a minor implementation detail. It creates an economic sequencing boundary: partial liquidation can leave residual debt unsocialized for one more step, allowing suppliers to exit before the final loss is imposed on the remaining pool.

The review test suite directly characterizes this behavior through:
- `test_Review_BadDebtSocializationCanBeDelayedByLeavingOneWeiCollateral`

This is one of the strongest issue candidates because it affects who ultimately bears losses, not just how accounting is displayed.

---

### 3. Liquidation branch choice and rounding are material review surfaces
Morpho liquidation is not a single path. The caller chooses between:
- `seizedAssets`
- `repaidShares`

Both branches compose oracle pricing, incentive math, and share conversions with protocol-favoring rounding. External audit results and the review harness both indicate that this is a genuine attack surface, especially for dust liquidations and low-liquidity markets.

The main concerns are:
- tiny partial liquidations creating path-dependent borrower outcomes
- collateral moving asymmetrically relative to debt reduction
- branch-specific rounding differences
- repeated dust liquidations becoming economically meaningful over time

The current tests give useful characterization coverage here, but liquidation rounding remains one of the most important areas for further adversarial testing.

---

### 4. Virtual balances both mitigate and distort
Morpho’s virtual shares / virtual assets are best understood as a mitigation, not a complete defense.

They can improve some empty-market conversion behavior, but they also act as economic participants in the math. In tiny markets, the review found meaningful reasons to track:
- supplier-side value not fully flowing to real LPs
- borrow-side residual recorded debt after real positions appear cleared
- low-liquidity share-price distortion
- fresh-market precision regimes that do not matter in mature markets

The review characterization tests directly support this thesis:
- `test_Review_VirtualSupplySharesCanLeavePartOfInterestOutsideRealSupplierClaim`
- `test_Review_VirtualBorrowSharesCanLeaveResidualDebtThatReducesWithdrawability`

This means virtual balances are not only a guardrail; they are also part of the accounting risk surface.

---

### 5. Lazy accrual is a protocol-level integration boundary
`_accrueInterest()` is the central accounting crystallization path in Morpho Blue.

It is where:
- borrower debt growth is recognized
- supplier-side asset growth is recognized
- fee dilution is recognized
- IRM output is sampled and propagated into market state

As a result, lazy accrual is not just a gas optimization choice. It is a protocol-level economic and integration boundary whose safety depends partly on the chosen IRM model.

The main review implication is that stateful or cadence-sensitive IRMs need explicit compatibility review around:
- zero-borrow states
- irregular accrual cadence
- many small updates versus one large update
- utilization spikes in low-liquidity markets

This is best treated as a major design/integration theme rather than a single isolated bug class.

## Strong Review-Supported Candidate Issues

### 1. Delayed bad-debt socialization via `1 wei` collateral residue
This is the strongest current candidate. The review harness directly shows that bad debt can be kept unrealized until the final unit of collateral is removed, creating a loss-allocation game across suppliers.

### 2. Virtual supply-share participation can leave part of tiny-market growth outside real LP claims
In tiny markets, market-level supply growth can exceed the growth captured by real supplier claims even without a protocol fee, suggesting that virtual supply balances can absorb part of the economic benefit.

### 3. Virtual borrow-share participation can leave tiny-market residual recorded debt that constrains withdrawal
In tiny markets, market-level borrow assets can remain even after the real borrower clears all owned borrow shares, creating residual debt that can restrict supplier exit.

### 4. Dust liquidation rounding behavior remains a meaningful adversarial surface
The current tests support the view that liquidation rounding and branch choice are meaningful economic surfaces, even where the review has not yet elevated every path into a finalized exploit claim.

## Review Limits / What Is Not Yet Fully Settled
The current review is strongest on accounting characterization and selected liquidation / bad-debt paths; some historically reported fresh-market issues remain only partially reproduced in the local harness.

- Candidate 5 in `issue-candidates.md` (first-borrower borrow-share inflation) is literature-backed but does not yet have a dedicated local reproduction test.
- Candidate 6 (manipulated supplier entry pricing) is supported by characterization and external findings, but does not yet have a dedicated manipulated-entry proof in the local suite.
- Candidate 7 (lazy accrual + stateful IRM path dependence) is currently best treated as a design/integration review theme rather than a near-term exploit claim on its own.

## Overall Assessment
Morpho Blue’s core accounting model is coherent under its intended assumptions, but those assumptions matter a great deal. In particular:
- low-liquidity and fresh-market behavior differs materially from mature-market behavior
- liquidation is an economic sequencing and rounding surface, not just a cleanup mechanism
- virtual balances both mitigate and create distortions
- lazy accrual is a major integration boundary for IRMs, not a cosmetic optimization
- safety depends materially on well-behaved tokens, correct oracle scaling and freshness, sane IRM behavior, and sensible enabled market parameters

The highest-signal security story is therefore not “Morpho accounting is broken.” It is:

`Morpho accounting is coherent in its intended model, but several economically important edge cases concentrate in fresh markets, dust-scale liquidations, virtual-balance effects, and lazy-accrual integration assumptions.`

That is where further review effort should stay focused.