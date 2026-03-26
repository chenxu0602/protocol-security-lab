# Invariants

## 1. First deposit should mint one-for-one shares when supply is zero
Why it matters:
Initial pricing should be well-defined.

How it could fail:
Incorrect zero-supply logic.

## 2. previewDeposit should match deposit in the same state
Why it matters:
Users rely on previews for expected mint output.

How it could fail:
State changes between preview and execution, or inconsistent conversion logic.

## 3. previewRedeem should match redeem in the same state
Why it matters:
Users rely on previews for expected redemption output.

How it could fail:
Execution path uses different rounding or state assumptions than preview path.

## 4. Donations should increase assets per share without increasing total share supply
Why it matters:
Direct asset transfers to the vault reprice all existing shares.

How it could fail:
The vault ignores externally donated assets or misprices conversions.

## 5. New depositors after a donation should receive fewer shares per asset than before
Why it matters:
Share price should reflect increased vault assets.

How it could fail:
Conversion logic ignores donation-driven asset increases.

## 6. Withdraw and redeem paths should not return more value than conversion logic permits
Why it matters:
Prevents users from extracting more assets than their shares justify.

How it could fail:
Bad rounding direction or inconsistent preview/execution logic.

## 7. Upward rounding should favor the vault on mint/withdraw paths, while downward rounding should favor the vault on deposit/redeem outputs
Why it matters:
Rounding direction is part of vault safety and fairness.

How it could fail:
Incorrect use of mulDivUp / mulDivDown.