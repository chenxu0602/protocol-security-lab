# Threat Model

## Protocol Summary
Morpho Blue is a singleton lending protocol where each market is defined by a `MarketParams` tuple:

- `loanToken`
- `collateralToken`
- `oracle`
- `irm`
- `lltv`

The core contract stores per-market accounting in `market[id]` and per-user accounting in `position[id][user]`, where `id = marketParams.id()`.

Markets are permissionlessly creatable once the owner has enabled the chosen IRM and LLTV. Interest is accrued lazily on user actions and through explicit `accrueInterest`, not continuously in storage.

Morpho Blue is intentionally minimal and governance-light, but this shifts more safety burden onto market parameter choice and external dependency correctness.

Markets are isolated by `MarketParams`, so risk is primarily market-local rather than pooled across unrelated assets.

## Actors

### Protocol / User-Side Actors
- Protocol owner
- Market creator
- Supply-side lender
- Borrower
- Collateral provider
- Liquidator
- Fee recipient
- Authorized delegate / operator
- Signature relayer
- Flash loan borrower

### External Dependencies
- Interest Rate Model (`irm`)
- Oracle
- Loan token
- Collateral token

## Trust Assumptions
- The owner only enables safe IRMs and LLTV values.
- The oracle returns correctly scaled and manipulation-resistant prices.
- The IRM returns economically sane borrow rates and does not re-enter or revert in ways that break liveness.
- `loanToken` and `collateralToken` behave close enough to standard ERC20 semantics:
  - no fee-on-transfer behavior
  - no unexpected burns on transfer
  - no reentrancy on transfer / transferFrom
  - balances change by exactly the transferred amount
- The virtual shares / virtual assets design in `SharesMathLib` improves empty-market behavior without creating unacceptable distortions at realistic sizes.
- The virtual shares / virtual assets design should be treated as a mitigation, not a full defense:
  - it can improve some zero-state and donation-style edge cases
  - it does not eliminate fresh-market / low-liquidity manipulation
  - it mainly changes the scale and geometry of the attack surface
  - in some accounting paths, it may itself create or amplify economic distortion:
    - virtual supply shares can absorb part of the growth that real suppliers expected to capture
    - virtual borrow shares can participate in debt growth even though no user owns them
- Liquidators and flash loan borrowers can use arbitrary atomic capital and arbitrary callback logic.

## External Trust Boundaries
- `IOracle.price()`
  determines collateral valuation and directly drives `_isHealthy()` and liquidation math.
- `IIrm.borrowRate()`
  determines accrued interest and fee-share minting.
- `onMorphoSupply`
- `onMorphoRepay`
- `onMorphoSupplyCollateral`
- `onMorphoLiquidate`
- `onMorphoFlashLoan`

These callback boundaries are not merely integration conveniences; they are meaningful control-flow boundaries inside accounting-critical operations.

## Accounting Anchors
- The main market accounting anchor is `market[id]`, especially:
  - `totalSupplyAssets`
  - `totalSupplyShares`
  - `totalBorrowAssets`
  - `totalBorrowShares`
  - `lastUpdate`
  - `fee`
- The main user accounting anchor is `position[id][user]`, especially:
  - `supplyShares`
  - `borrowShares`
  - `collateral`
- Interest is accrued lazily in `_accrueInterest()` based on elapsed time since `lastUpdate`.
- Supply-side and borrow-side conversions are done through `SharesMathLib`, which uses virtual shares and virtual assets.
- Health checks are performed against:
  - debt converted from `borrowShares`
  - collateral valued by the oracle
  - `lltv`
- Position safety is determined from oracle-valued collateral and share-derived debt, which may diverge from the practical proceeds available under stressed liquidation conditions.

Lazy accrual is not just a gas-saving implementation detail. In Morpho Blue it is a protocol-level economic boundary:
- debt growth is crystallized there
- supplier-side asset growth is crystallized there
- fee dilution is crystallized there
- IRM behavior is sampled there and propagated into accounting

That means `_accrueInterest()` correctness depends not only on arithmetic, but also on whether the chosen IRM remains well-behaved across:
- zero-borrow states
- irregular accrual cadence
- many small updates versus one large update
- any internal state transitions performed by `borrowRate()`

## Main Review Surfaces

### Owner / Configuration Surface
- `enableIrm`
- `enableLltv`
- `setFee`
- `setFeeRecipient`
- `setOwner`

The owner cannot directly create arbitrary borrow positions, but can decide which IRMs and LLTVs are valid for new markets and can change fee extraction on existing markets.

### Market Creation Surface
- `createMarket`

Market creation is permissionless once the IRM and LLTV have been enabled. Review attention should therefore focus less on creation access itself and more on whether dangerous external dependencies can be whitelisted and then reused indefinitely.

### Supply / Borrow / Repay / Withdraw Surface
- `supply`
- `withdraw`
- `borrow`
- `repay`
- `supplyCollateral`
- `withdrawCollateral`

These flows update market and position accounting before or around external token transfers and, in some cases, before callbacks into the caller.

### Liquidation Surface
- `liquidate`

Liquidation is permissionless and depends directly on:
- oracle price
- liquidation incentive math
- share-to-asset conversions
- bad debt handling when collateral is exhausted

### Flash Loan Surface
- `flashLoan`

Flash loans are permissionless, uncollateralized, and callback-driven. They should be reviewed under the assumption that sophisticated atomic-capital strategies are always available to users and adversaries.

### Delegation / Signature Surface
- `setAuthorization`
- `setAuthorizationWithSig`

Morpho allows account-level delegation and EIP-712 signature-based delegation. This creates a replay, nonce, expiry, and signer-validation surface, and also expands the authority model for supply / borrow / withdraw / collateral operations.

### Storage Inspection Surface
- `extSloads`

This function is read-only. It is mainly an introspection feature, not an accounting mutation feature.

## Main Economic Risk Questions
- Can lazy interest accrual create meaningful path dependence between otherwise similar user actions?
- Can IRM behavior or owner-enabled IRM choice create insolvency, overflow, or liveness failure through extreme borrow rates?
- Can fee minting during `_accrueInterest()` dilute suppliers in ways that are unexpected or sensitive to timing?
- Can oracle scale assumptions or price manipulation make `_isHealthy()` and liquidation outcomes incorrect?
- Can liquidation rounding, incentive math, or bad-debt cleanup create unfair transfers or edge-case insolvency?
- Can callback-based flows be abused to create reentrancy, inconsistent pull/payment assumptions, or state that is only safe if the final transfer succeeds?
- Can authorization and signature flows let an attacker replay, front-run, or overextend account-management permissions?
- Can supply/borrow share conversions around tiny markets or manipulated balances create precision or inflation-style edge cases despite virtual shares?
- Does the virtual-share design merely push manipulation into low-liquidity / fresh-market regimes rather than eliminate it?
- Can the virtual-share design itself create supplier-side value leakage or borrower-side ghost debt through the way unrealized virtual balances participate in share math?

## Code-Specific Risk Themes From `Morpho.sol`
- Interest accrual is lazy and stateful: any function that calls `_accrueInterest()` can observe a meaningfully different accounting state than a function that does not.
- For stateful IRMs, lazy accrual is also an integration boundary: compatibility depends on whether the IRM behaves correctly when accrual is called at irregular times, after long gaps, or from edge states such as zero-borrow markets.
- Virtual shares mitigate some empty-market precision issues, but the main remaining review question is what still breaks in low-liquidity markets:
- Virtual shares are also an accounting participant, not merely a guardrail. The main review question is therefore both what they mitigate and what they themselves distort:
  - first-borrower borrow-share inflation
  - supply share-price distortion
  - stateful IRM manipulation
  - hard-to-clear residual debt states
  - supplier-side interest leakage into unowned virtual supply shares
  - borrower-side ghost debt growth tied to virtual borrow shares
- `supplyCollateral()` intentionally skips interest accrual for gas reasons, while `withdrawCollateral()` does accrue and re-check health. This asymmetry is likely intentional, but it is worth reviewing whether sequencing around collateral top-ups, delayed accrual, and subsequent health checks creates any surprising edge cases.
- Liquidation allows the caller to specify either:
  - `seizedAssets`
  - or `repaidShares`
  and computes the other side internally with rounding. This is a meaningful review surface.
- `flashLoan()` transfers tokens out, calls back into the borrower, then pulls tokens back with `transferFrom`. Atomicity protects repayment, but the callback still gives the borrower arbitrary one-transaction control flow.
- `setAuthorizationWithSig()` increments nonce as part of validation and does not reject “already set” states, by design. This is an intentional behavioral detail worth remembering during review.
- `extSloads()` is harmless from a write-safety perspective, but can help external actors inspect accounting state with high precision.

## Initial Review Priorities
- Review `_accrueInterest()` and fee-share minting as the main accounting crystallization path.
- Review stateful IRM compatibility with `_accrueInterest()`, especially around zero-borrow states and whether many small accrual steps behave coherently relative to one large accrual step.
- Review health-check and liquidation math under realistic and edge-case oracle values.
- Review supply / borrow / repay / withdraw rounding directions and whether they consistently favor protocol safety.
- Review callback-enabled flows for reentrancy assumptions and whether all important invariants rely on final token pulls succeeding.
- Review authorization and signature delegation for replay resistance and authority boundaries.
- Review fresh-market / low-liquidity behavior as its own risk regime, especially where virtual shares mitigate but do not eliminate:
  - first-borrower griefing
  - supplier share-price manipulation
  - low-liquidity IRM pathologies
  - residual dust / borrow-share distortions
