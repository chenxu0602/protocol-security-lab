# Finding

## Title
`withdraw()` performs external interaction before state updates, enabling reentrant double-withdrawal

## Severity Guess
High

## Impact
An attacker can withdraw more ETH than their recorded balance entitles them to by re-entering `withdraw()` before storage is updated. This allows direct theft of vault funds from other depositors.

## Likelihood
High

## Description
In `ReentrantBuggyVault.withdraw(uint256 amount)`, the contract transfers ETH to `msg.sender` before decrementing:
- `balanceOf[msg.sender]`
- `totalAssets`

Because control is handed to an untrusted external recipient before internal accounting is updated, a malicious receiver contract can re-enter `withdraw()` during the transfer.

At the time of re-entry, the attacker's recorded balance is still unchanged, so the second withdrawal passes the balance check and transfers additional ETH.

## Attack Path
1. Victim deposits ETH into the vault
2. Attacker deposits `1 ETH`
3. Attacker calls `withdraw(1 ether)`
4. Vault sends ETH before updating accounting
5. Attacker re-enters `withdraw(1 ether)` in `receive()`
6. Second withdrawal passes because recorded balance is still `1 ETH`
7. Attacker receives a second payout
8. Storage updates occur only after both transfers

## Broken Invariant
A user should never be able to extract more value than their recorded balance.

## Proof / Test Idea
Demonstrated by `testReentrancyAttackDrainsExtraFunds()`:
- attacker starts with `1 ETH`
- attacker deposits `1 ETH`
- attacker ends with `2 ETH`
- vault loses `1 ETH`

## Recommended Fix
Apply Checks-Effects-Interactions ordering:
1. validate inputs
2. update `balanceOf[msg.sender]` and `totalAssets`
3. only then transfer ETH

Example fix:
```solidity
balanceOf[msg.sender] -= amount;
totalAssets -= amount;

(bool ok, ) = payable(msg.sender).call{value: amount}("");
require(ok, "transfer failed");