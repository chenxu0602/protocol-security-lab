# Finding

## Title
`withdraw()` does not decrement `totalAssets`, causing accounting drift

## Severity Guess
Medium

## Impact
Internal accounting becomes inconsistent after withdrawals. `totalAssets` overstates actual managed assets, which breaks protocol invariants and can lead to incorrect downstream logic in more complex designs.

## Likelihood
High

## Description
In `BuggyVault.withdraw(uint256 amount)`, the contract decrements `balanceOf[msg.sender]` but fails to decrement `totalAssets`.

As a result, after a successful withdrawal:
- the user's recorded balance decreases
- ETH leaves the contract
- but `totalAssets` remains unchanged

This creates accounting drift between aggregate protocol accounting and the sum of user balances.

## Attack Path
1. User deposits ETH
2. User withdraws part of their balance
3. `balanceOf[msg.sender]` decreases
4. ETH is transferred out
5. `totalAssets` does not decrease
6. Internal accounting no longer matches actual intended state

## Proof / Test Idea
The issue is demonstrated by:
- `testWithdrawShouldReduceTotalAssets()`
- `testMultipleUsersAccountingStaysConsistent()`

Both tests fail because `totalAssets` remains too high after withdrawal.

## Recommended Fix
Decrement `totalAssets` by `amount` inside `withdraw()` before the external call.

Example fix:
```solidity
totalAssets -= amount;