# Threat Model

## Protocol Summary
Aave V3 is a pooled, over-collateralized lending protocol. Users can:
- supply assets and receive aTokens
- withdraw supplied assets
- borrow assets against enabled collateral
- repay debt using underlying or aTokens
- liquidate unhealthy positions
- access flash liquidity through flash loans

The protocol maintains reserve-level accounting, user-level debt/collateral state,
and account-level solvency through health factor calculations.

## Actors
- governance / risk admin / pool configurator
  
  sets reserve parameters, collateral settings, caps, liquidation thresholds, reserve factors, 
  and interest-rate references

- supplier / withdrawer
 
  supplies liquidity and receives aTokens, or withdraws underlying

- borrower / repayer

  borrows against collateral and repays using underlying or aTokens

- liquidator
  
  repays part of an unhealthy borrower's debt and receives discounted collateral

- flash loan receiver

  temporarily accesses pool liquidity and must return amount plus premium atomically unless the path explicitly opens debt

- oracle / oracle sentinel

  provides asset prices and may constrain protocol actions during oracle failure conditions

- interest rate strategy contract

  computes reserve liquidty / borrow rates based on reserve state

- aToken / variableDebtToken / stableDebtToken implementations

  realize tokenized reserve accounting and debt accounting


## Trust Assumptions
- Reserve assets behave sufficiently like supported ERC20s for transfer and balance semantics.
- Governance / configurator is trusted to set economically coherent reserve parameters.
- Oracle inputs are trusted within the protocol’s oracle model.
- Oracle freshness and liveness are trusted within the protocol’s oracle/sentinel model.
- Interest-rate strategy contracts are trusted to implement intended rate logic.
- aToken / stable debt token / variable debt token implementations are trusted to preserve reserve accounting semantics.
- Special privileged modules such as bridge-related paths are out of main scope unless explicitly reviewed.


## External Trust Boundaries
- oracle pricing
- interest-rate strategy contract
- ERC20 asset behavior
- address provider / governance-configured module wiring
- special modules such as bridge and privileged flash-borrower paths


## Assets / Security Properties to Protect
- user collateral and borrowed assets
- reserve solvency and reserve accounting consistency
- correctness of tokenized claims (aToken / debt token)
- correctness of user account data and health factor
- correctness of liquidation pricing, close factor and seized collateral
- correctness of interest accrual, liquidity index and borrow indexes
- correctness of protocol fee and treasury accrual
- correctness of flash loan repayment and premium accounting


## Accounting Anchors
- reserve state and reserve cache must reconcile
- aToken supply-side accounting must remain consistent with reserve liquidity accounting
- stable and variable debt accounting must reconcile with reserve debt state
- userConfig must remain consistent with actual supplied / borrowed positions
- user account data must remain consistent with reserve-level state
- liquidity index and variable borrow index must evolve consistently with rate accrual
- protocol treasury accrual must not double count or leak value
- repay using underlying and repay using aTokens should be economically coherent


## Main Review Surfaces
- GenericLogic

  user account data, collateral valuation, debt valuation and health factor
- SupplyLogic

  supply / withdraw paths, aToken mint / burn behavior and collateral enablement
- BorrowLogic

  borrow / repay paths, stable vs variable debt behavior, rate updates and repayment with aTokens
- LiquidationLogic

  liquidation validation, debt-to-cover calculation, collateral seize calculation, liquidation fee / protocol fee handling
- ReserveLogic

  index accrual, treasury accrual, reserve updates and rate updates
- FlashLoanLogic

  validation, callback boundary, repayment accounting and premium split
- Configuration / reserve paramter handling

  LTV, liquidation threshold, reserve factor, caps, isolation / eMode constraints


## Main Threat Surfaces
- incorrect collateral or debt valuation causing wrong solvency assessment
- health factor boundary errors leading to wrongful liquidation or missed liquidation
- incorrect debt burn / aToken burn / underlying transfer ordering during repay and liquidation
- drift between reserve-level accounting and user-level tokenized accounting
- desynchronization between userConfig flags and actual supplied / borrowed state
- incorrect treasury accrual or reserve factor application
- rounding / precision issues in scaled balance and index-based accounting
- inconsistent behavior between repay-with-underlying and repay-with-aTokens
- flash loan callback or repayment path causing accounting inconsistency
- reserve parameter or mode interactions creating invalid borrowing or collateral states
- stable debt and variable debt paths diverging from intended economic behavior


## High-Value Review Questions
- Can a user become liquidatable too early or remain non-liquidatable too long?
- Can repay or liquidation reduce debt incorrectly relative to actual asset movement?
- Can reserve accounting and token accounting drift under accrual?
- Can protocol fee or treasury accrual take too much or too little?
- Are stable debt and variable debt paths internally consistent?
- Do aToken-scaled accounting semantics preserve correct user balances across mint/burn/repay?
- Are reserve parameter changes reflected consistently in user-level solvency logic?