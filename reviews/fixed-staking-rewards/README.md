# Review Scope

## Target
`FixedStakingRewards`

## Main Files in Scope
- `src/review/FixedStakingRewards.sol`
- `src/review/interfaces/IStakingRewards.sol`
- `src/review/interfaces/IChainlinkAggregator.sol`

## Review Goal
This is a learning-oriented external code review focused on staking and reward-accounting mechanics, with emphasis on state transitions, accrual correctness, fairness across users, and security-relevant invariants.

## What the system does
`FixedStakingRewards` allows users to stake a token and earn rewards over time. It includes user actions such as staking, withdrawing, claiming rewards, and exiting, together with owner-controlled functions for pausing, whitelisting, configuring reward behavior, supplying rewards, and handling rebalance/oracle-related logic.

## Why These Files Are In Scope
- `FixedStakingRewards.sol` contains the core staking, reward accrual, claim, and admin logic.
- `IStakingRewards.sol` defines the contract-facing interface and helps clarify expected external behavior.
- `IChainlinkAggregator.sol` is relevant because the contract includes oracle-dependent rebalance logic and stale/zero-price handling.

## Out of Scope
- Full repository-wide audit outside the files above
- Deployment scripts, CI, and tooling
- Economic/business viability of the broader product
- Offchain oracle correctness beyond contract-side handling assumptions
- Governance/process risks outside contract-enforced logic

## Main Review Themes
- Reward accrual accounting
- Correctness of `earned`, `rewardPerToken`, and update flows
- Stake / withdraw / getReward / exit state transitions
- Multi-user fairness
- Pause and whitelist interactions with principal and accrued rewards
- Admin-controlled reward-rate / yield / rebalance changes
- Oracle freshness and zero-value handling
- Token transfer and integration assumptions

## Initial Review Questions
- Can one user’s timing capture or distort another user’s rewards?
- Are reward updates applied consistently before balance-changing actions?
- Can owner-controlled parameter changes break reward accounting?
- Do pause and whitelist changes preserve principal and already-earned rewards?
- Does rebalance fail safely when oracle data is stale or zero?
- Are there assumptions about staking token or reward token behavior that could break accounting?

## Expected Deliverables
- `threat-model.md`
- `function-notes.md`
- `invariants.md`
- `issue-candidates.md`
- `final-review.md`