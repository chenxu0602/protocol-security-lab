# Invariants

## 1. Benign Round Trip Should Not Create Risk-Free Profit
- Statement:
  In a stable state with no report, no fee minting, no loss, and no external economic change, deposit-then-immediate redeem / withdraw should not create a free gain.
- Why it matters:
  This is the baseline sanity check for the stored `totalAssets` and effective `totalSupply` model.
- How to test:
  Deposit, then immediately redeem or withdraw in the same state and confirm any difference is only bounded rounding loss.

## 2. Same-State Preview And Execution Should Match
- Statement:
  If state does not change between preview and execution, `previewDeposit`, `previewMint`, `previewWithdraw`, and `previewRedeem` should match the actual path up to intended rounding direction.
- Why it matters:
  Same-state mismatch is a stronger signal of broken accounting than mismatch after report or unlock progression.
- How to test:
  Call preview functions and immediately execute the matching action in the same block / state, then compare outputs.

## 3. Deposits Should Price Against Stored Accounting, Not Raw Balance Noise
- Statement:
  Entry pricing should be based on the intended accounting anchor rather than direct token donations or unrelated loose-balance changes.
- Why it matters:
  The strategy explicitly stores `totalAssets` to prevent donation-driven PPS manipulation.
- How to test:
  Donate assets directly to the strategy without reporting, then compare deposit pricing before and after the donation.

## 4. Fresh Depositors Should Not Instantly Capture Locked Profit
- Statement:
  After a profitable `report()`, a late depositor should not be able to buy into already-earned but still-locked profit at an unfair discount.
- Why it matters:
  This is one of the main economic promises of the profit-locking design.
- How to test:
  Have user A deposit, realize profit through `report()`, then let user B deposit immediately after and compare B’s entry price and later claim versus A’s.

## 5. Positive Report Should Not Cause Unexplained Immediate Harm To Existing Users
- Statement:
  A positive `report()` should not reduce existing users’ economic position except through intended fee dilution.
- Why it matters:
  Profit is supposed to be locked and later unlocked, not immediately extracted from users by accounting error.
- How to test:
  Deposit, realize profit with and without fees, inspect PPS and user claim immediately after report, then compare with the expected fee effect.

## 6. Fee Minting Should Stay Within Intended Economics
- Statement:
  Shares minted to performance fee and protocol fee recipients should not exceed what the configured fee parameters imply.
- Why it matters:
  Fee shares dilute existing users, so over-minting is a direct economic bug.
- How to test:
  Run profitable reports under different fee configurations and verify recipient share minting matches the formula implied by reported profit and protocol fee split.

## 7. Exit Loss Realization Should Be Coherent
- Statement:
  If `_freeFunds()` cannot fully satisfy an exit, the realized shortfall should be reflected coherently in assets returned, shares burned, and `totalAssets` reduction.
- Why it matters:
  Exit paths are where accounting and real liquidity collide; incoherence here causes hidden value transfer.
- How to test:
  Simulate partial liquidity in `_freeFunds()`, then compare requested assets, returned assets, burned shares, and post-exit accounting.

## 8. Withdraw And Redeem Should Only Diverge For Documented `maxLoss` Reasons
- Statement:
  `withdraw()` and `redeem()` may differ under loss because of their default `maxLoss` behavior, but should not diverge for arbitrary or unexplained reasons.
- Why it matters:
  Path dependence beyond documented semantics is a strong source of user surprise and accounting fragility.
- How to test:
  Run identical loss scenarios through both paths and confirm the difference is explained by `maxLoss` defaults rather than unrelated pricing inconsistency.

## 9. Locked Profit Should Decay Monotonically Between Reports
- Statement:
  In the absence of a new `report()`, locked strategy-held shares should only move toward fully unlocked over time.
- Why it matters:
  The time-based unlock path is a core state machine that directly changes effective supply and PPS.
- How to test:
  After a profitable report, advance time in steps and verify unlocked shares increase monotonically while effective locked shares decrease monotonically.

## 10. Repeated No-Op Reports Should Not Create Value Drift
- Statement:
  If `_harvestAndReport()` returns the same total asset value and there is no real economic change, repeated `report()` calls should not create meaningful gain, loss, or dilution.
- Why it matters:
  Keeper cadence should not manufacture value by itself when nothing economically changed.
- How to test:
  Use an honest mock strategy with unchanged total assets, call `report()` multiple times, and compare user claims, PPS, total supply, and fee state across repetitions.
