# Invariants

## 1. totalAssets equals sum of all user balances
Why it matters: 
Internal accounting should not drift.

How it could fail:
A function updates one side of accounting but not the other.

## 2. A user cannot withdraw more than their recorded balance
Why it matters: 
Prevents direct theft.

How it could fail:
Missing or incorrect balance check.

## 3. deposit() increases both user balance and totalAssets by the same amount
Why it matters: 
Prevents partial accounting updates.

How it could fail:
One variable updates while other does not.

## 4. withdraw() decreases both user balance and totalAssets by the same amount
Why it matters:
Preserves accounting consistency.

How it could fail:
Incorrect state updates or order-of-operations bug.

## 5. One user's actions should not reduce another user's recorded balance
Why it matters: 
Ensure user isolation.

How it could fail:
Shared storage mistake or broken account logic.


## 6. A user must not be able to withdraw more total value than their recorded balance
Why it matters:
Prevents reentrant or multi-step over-withdrawal.

How it could fail:
External interaction occurs before accounting updates.