# Threat Model

## Protocol Summary
Staking contract that allows users to stake tokens and earn rewards at a fixed rate.

## Main Actors / Roles
- Staker
- Withdrawer

## Trust Assumptions
- `earned(address account)` correctly represents the user's available rewards
- Asset transfers succeed as expected
- No hidden asset loss occurs outside modeled behavior
- Owner set the correct APY

## Privileged Roles
- Owner can move funds and select whilelist accounts

## External Dependencies
- Underlying SafeERC20 token behavior
- Safe transfer semantics
- `_rebalance()` implementation of rewardRate 

## Fund Flows
- Assets enter through `stake()`
- Assets leave through `withdraw()` and `getReward()` and `exit()` and `reclaim()`

## Core State Transitions
- `stake(amount)` -> transfer assets in, mint shares out
- `withdraw(assets)` -> compute shares to burn, burn shares, transfer assets out
- `getReward()` -> get the rewards
- `exit()` -> withdraw and get rewards

## Core Invariants
- Total staked
- Share/asset conversion should remain internally consistent
- Entry and exit paths should respect intended rounding direction

## Potential Attack Surfaces
- Manipulate block time
- Initial rewards might be too small
- Add/remove whitelist could be address(0)
- currentRewardTokenRate could be manipulated
- recoverERC20 might be manipulated
- currentRewardTokenRate from `_rebalance()` might be manipuated