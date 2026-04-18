# Invariants

## 1. Healthy positions should not be liquidatable
If a user's health factor is at or above the liquidation threshold, liquidation must revert.

Review intent:
- Prevent wrongful liquidation of solvent users
- Catch valuation drift, oracle misuse, or boundary rounding errors around HF = 1

---

## 2. Liquidation settlement should remain value-coherent
For a valid liquidation:
- debt repaid must match debt burned
- collateral seized must be consistent with oracle pricing, liquidation bonus, and protocol liquidation fee
- the protocol must not seize more collateral than the user actually has

Review intent:
- Prevent debt/collateral mismatch
- Prevent over-seizure or under-burn during liquidation

---

## 3. Supply should increase user claim and reserve liquidity coherently
A new supply should:
- increase reserve-side liquidity consistently
- mint the correct aToken claim using the current liquidity index
- preserve reconciliation between reserve accounting and token accounting

Review intent:
- Ensure supply-side accounting is internally coherent
- Catch stale-index or scaled-balance mistakes

---

## 4. Treasury accrual should be monotone absent explicit reset paths
Protocol treasury accrual should not decrease during normal accrual, borrow, repay, liquidation, or flash loan paths unless an explicit mint-to-treasury, reset, or governance path justifies it.

Review intent:
- Catch negative treasury drift
- Catch reserve-factor accounting errors

---

## 5. Repay with underlying and repay with aTokens should be economically coherent
For the same user, reserve, and repay amount:
- repay via underlying
- repay via aTokens

should reduce debt by approximately the same economic amount, subject only to expected rounding and index effects.

Review intent:
- Ensure repay path equivalence
- Catch divergence between debt-side settlement and asset-side settlement

---

## 6. Flash loan repayment should not reduce reserve value
A completed flash loan should not reduce reserve value.
After successful repayment:
- principal must be returned
- premium must be accounted for
- reserve value should be weakly higher than before the flash loan, up to expected rounding

Review intent:
- Catch repayment shortfall
- Catch incorrect premium split or reserve update ordering

---

## 7. Parameter changes should not retroactively rewrite accrued user claims
Configuration changes such as:
- LTV
- liquidation threshold
- reserve factor
- borrow caps
- eMode parameters

may change future behavior and solvency conditions, but should not retroactively erase or distort already accrued aToken / debt-token accounting.

Review intent:
- Separate policy changes from accounting corruption
- Catch config mutations that improperly rewrite existing balances

---

## 8. Valid liquidation should not worsen borrower solvency accounting
After a successful liquidation, the borrower’s position should be at least as economically consistent as before.
In particular:
- debt should not increase
- seized collateral should match liquidation rules
- userConfig flags should remain synchronized with actual remaining balances
- health factor should not become worse purely because of liquidation accounting error

Review intent:
- Catch liquidation paths that make the position less coherent
- Catch collateral-bit / debt-bit desynchronization after liquidation