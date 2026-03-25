# Invariants

## 1. totalAssets equals sum of all user balances
Why it matters: prevents accounting drift.

## 2. A user cannot withdraw more than their balance
Why it matters: prevents direct theft.

## 3. deposit must increase both user balance and totalAssets by the same amount
Why it matters: keeps internal accounting consistent.

## 4. one user's withdraw must not reduce another user's recorded balance
Why it matters: user isolation.
