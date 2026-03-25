# Threat Model

## Protocol Summary
A minimal ETH vault where users deposit ETH and can later withdraw up to their recorded balance.

## Main Actors / Roles
- User
- Contract

## Trust Assumptions
- Internal accounting is the source of truth
- ETH transfers either succeed or the whole transaction reverts

## Privileged Roles
None

## External Dependencies
- Native ETH transfer via call

## Fund Flows
- ETH enters through `deposit()`
- ETH leaves through `withdraw(uint256 amount)`

## Core State Transitions
- `deposit()` increases `balanceOf[msg.sender]` and `totalAssets`
- `withdraw()` decreases `balanceOf[msg.sender]` and `totalAssets`, then transfers ETH out

## Core Invariants
- `totalAssets` should equal the sum of all user balances
- A user cannot withdraw more than their recorded balance
- Deposit and withdraw should keep internal accounting consistent

## Potential Attack Surfaces
- External call during `withdraw()`; reentrancy should be reviewed
- Accounting mismatch between `totalAssets` and user balances
- ETH transfer failure / recipient behavior