# Final Review

## Protocol Summary
`FixedStakingRewards` is a staking contract that accepts a staking token, mints ERC20 share balances (`FSR`) to represent staked principal, and distributes a separate reward token over time. Reward accrual is tracked through a global reward index (`rewardPerTokenStored`) plus per-user checkpoints (`userRewardPerTokenPaid` and `rewards[account]`).

The contract also includes strong owner-controlled operational features:
- whitelist management
- pause / unpause
- reward funding
- APY / reward-rate configuration
- reward release timing
- reward-token reclaim and ERC20 recovery
- oracle-dependent rebalance logic

## In-Scope Files
### Core Contract
- `src/review/FixedStakingRewards.sol`

### Supporting Interfaces
- `src/review/interfaces/IStakingRewards.sol`
- `src/review/interfaces/IChainlinkAggregator.sol`

## Review Approach
This review focused on:
- manual code review of state transitions and reward-accounting logic
- review of owner and operational control surfaces
- review of oracle/rebalance behavior
- review of whitelist / pause interactions with principal and rewards
- execution of the project’s own test suite
- additional targeted review tests to validate issue candidates

The project’s own test suite already covered a large amount of intended functionality, including staking, withdrawal, reward claims, reward updates, admin controls, and rebalance/oracle paths. The additional review work therefore focused on:
- trust assumptions
- accounting-vs-reserve mismatches
- user-funds access risks
- design behaviors that may be acceptable but security-relevant

## Main Attack Surfaces
- reward accrual accounting and checkpointing
- multi-user fairness around balance changes and reward updates
- owner-controlled reward configuration and shutdown behavior
- reward-token reserve sufficiency versus accounting claims
- whitelist and pause controls over already-staked users
- oracle freshness and rebalance logic
- external self-call behavior inside `withdraw()`

## Core Security Properties Reviewed
- rewards should be checkpointed before user balance changes
- one user should not improperly erase or steal another user’s accrued rewards
- share balances should remain aligned with staked principal under intended token assumptions
- APY/reward-rate changes should preserve already-accrued rewards
- whitelist/pause changes should not unintentionally trap user funds unless explicitly intended
- reclaim/recovery behavior should not silently invalidate outstanding user reward expectations
- oracle failure should not corrupt reward accounting

## Confirmed Issue Candidates / Strong Risks

### 1. Whitelist removal can trap user principal and accrued rewards
A user who has already staked can later be removed from the whitelist and become unable to:
- withdraw principal
- claim rewards
- use `exit()`

This was confirmed by targeted review testing: after whitelist removal, `withdraw()`, `getReward()`, and `exit()` all reverted with `NotWhitelisted`, while the user still retained FSR balance and accrued rewards in contract accounting. :contentReference[oaicite:0]{index=0}

#### Why this matters
This is a strong control surface over user funds, not merely an entry restriction. If this is intended, it should be explicit policy. If not intended, it is a serious trapped-funds risk.

#### Classification
Strong design / access-control / user-funds risk.

---

### 2. `reclaim()` can drain reward-token reserves while accounting still shows user claims
`reclaim()`:
- sets reward availability to `block.timestamp`
- zeroes APY and reward rate
- transfers all reward tokens to the owner

Targeted review testing confirmed that after rewards were checkpointed for a user, calling `reclaim()` could leave:
- `rewards[user]` / `earned(user)` still showing a claim
- but `rewardsToken.balanceOf(address(this)) == 0`
- and `getReward()` then failing due to insufficient reward-token balance. :contentReference[oaicite:1]{index=1}

#### Why this matters
This creates a mismatch between:
- accounting-side reward entitlement
- actual reserve backing

#### Classification
Strong admin / reserve-backing / user-claim risk.

---

### 3. `recoverERC20()` can remove reward-token backing needed for accrued claims
Although `recoverERC20()` blocks recovery of the staking token, it allows recovery of other ERC20s, including the reward token.

Targeted review testing confirmed that the owner can recover all reward tokens while user reward accounting still shows accrued claims, after which `getReward()` fails because reserves are gone. :contentReference[oaicite:2]{index=2}

#### Why this matters
Even if intended as an admin power, this is a very strong trust assumption and can economically invalidate user reward expectations.

#### Classification
Strong admin / reserve-backing / trust-model risk.

---

## Confirmed Notable Design Behavior

### 4. `withdraw()` intentionally succeeds even if rebalance fails
`withdraw()` performs:

```solidity
try FixedStakingRewards(address(this)).rebalance() {} catch {}
```


## Overall Assessment

The main security story of `FixedStakingRewards` is not only reward-accounting correctness, but the extent to which user reward claims depend on owner honesty.

Targeted review testing confirmed that the owner has multiple ways to defeat or economically neutralize user reward expectations:

- `reclaim()` can remove all reward-token reserves while accounting-side claims remain
- `recoverERC20()` can remove reward-token backing needed to satisfy accrued rewards
- whitelist removal can prevent users from withdrawing principal or claiming rewards

Taken together, these behaviors mean that accrued rewards are not strongly protected claims against the contract’s reward reserves. Instead, they remain subject to strong owner discretion and operational policy.

This may be intended by design, but it should be treated as a major trust-model property rather than a minor administrative detail.