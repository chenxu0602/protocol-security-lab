# Invariants

## 1. Reward accrual must be checkpointed before any balance change
### Statement
Before a user’s FSR share balance changes, their accrued rewards should first be brought current using the existing global reward state.

### Why It Matters
If balance changes happen before reward checkpointing, users may:
- gain rewards they did not earn
- lose rewards they already earned
- distort reward allocation across users

### Relevant Mechanisms
- `updateReward(account)`
- `_update(address from, address to, uint256 value)`
- `stake()`
- `withdraw()`
- `getReward()`

### What Could Break It
- missing `updateReward` on a balance-changing path
- updating balances before reward checkpointing
- incorrect handling of mint/burn/transfer flows

---

## 2. A user’s accrued rewards should not decrease unexpectedly except through intended claim or shutdown logic
### Statement
For a user who has not claimed rewards, their accrued reward state should not decrease unexpectedly under normal operation.

### Why It Matters
Users should not lose already-earned rewards due to:
- another user’s actions
- admin parameter updates
- rebalance calls
- pause/whitelist transitions

### Relevant Variables
- `rewards[account]`
- `userRewardPerTokenPaid[account]`
- `rewardPerTokenStored`
- `lastUpdateTime`

### What Could Break It
- incorrect `updateReward` sequencing
- bad reward-rate update logic
- admin/state transitions that overwrite or invalidate user reward state

---

## 3. One user’s actions should not improperly erase or steal another user’s accrued rewards
### Statement
A user staking, withdrawing, transferring FSR, or claiming rewards should not improperly reduce another user’s already-earned rewards.

### Why It Matters
This is the core multi-user fairness property.

### Relevant Flows
- `stake()`
- `withdraw()`
- `getReward()`
- `exit()`
- `_update()`

### What Could Break It
- incorrect global index update logic
- missing user checkpoint update
- incorrect interaction between `from` and `to` in `_update()`
- admin-triggered state changes that shift accrued value unfairly

---

## 4. Share balances must track staked principal consistently
### Statement
FSR token balances should consistently represent staked principal, and mint/burn operations should correspond to intended stake/withdraw flows.

### Why It Matters
If FSR shares diverge from actual staked principal accounting, then:
- reward allocation becomes wrong
- withdrawals may return too much or too little
- supply-based reward calculations become unreliable

### Relevant Flows
- `_mint(msg.sender, amount)` in `stake()`
- `_burn(msg.sender, amount)` in `withdraw()`
- inherited ERC20 balance/supply accounting

### What Could Break It
- mint-before-transfer with non-standard staking token behavior
- fee-on-transfer staking token
- failed or partial transfer assumptions
- transferability of FSR creating unintended reward behavior

---

## 5. Reward claims should not exceed the intended funded reward capacity under normal operation
### Statement
The contract should not promise or pay rewards at a level that exceeds funded reward availability under intended operating assumptions.

### Why It Matters
Reward accounting can look correct internally while the pool is economically underfunded.

### Relevant Flows
- `stake()`
- `supplyRewards()`
- `getReward()`
- `reclaim()`
- `getRewardForDuration()`
- `rewardRate`

### What Could Break It
- insufficient reward-funding check design
- mismatch between 14-day sufficiency check and actual obligations
- owner reclaiming reward tokens while users still have accrued claims
- APY changes increasing obligations unexpectedly

---

## 6. Reward-rate changes must preserve already-accrued rewards
### Statement
When `targetRewardApy` or `rewardRate` changes, rewards already accrued up to that point must remain correctly attributed.

### Why It Matters
Admin-controlled reward changes should affect future accrual, not silently rewrite past accrual.

### Relevant Flows
- `setRewardYieldForYear()`
- `rebalance()`
- `_rebalance()`
- `updateReward(address(0))`

### What Could Break It
- changing reward rate before settling global reward state
- incorrect ordering around `updateReward(address(0))`
- stale or manipulated oracle values feeding rebalance

---

## 7. Oracle failure should fail safely and not corrupt reward accounting
### Statement
If oracle data is stale or zero, rebalance-related logic should fail safely without leaving reward accounting in an invalid intermediate state.

### Why It Matters
This contract depends on external price data to set `rewardRate`. Oracle issues should not corrupt user reward checkpoints or global accounting.

### Relevant Flows
- `_rebalance()`
- `rebalance()`
- `stake()`
- `withdraw()` via external self-call
- `setRewardYieldForYear()`

### What Could Break It
- partial state update before revert
- swallowing rebalance failures in ways that create accounting inconsistency
- incorrect stale-data boundary handling
- bad decimal normalization

---

## 8. Pause and whitelist state changes should not unintentionally trap principal or already-accrued rewards unless explicitly intended by design
### Statement
Users should not unexpectedly lose the ability to recover principal or accrued rewards due to pause or whitelist state changes unless that restriction is clearly intended as protocol policy.

### Why It Matters
This contract applies `onlyWhitelisted` not only to staking, but also to:
- `withdraw()`
- `getReward()`
- `exit()`

That creates a strong control surface over user funds and claims.

### Relevant Flows
- `addToWhitelist()`
- `removeFromWhitelist()`
- `pause()`
- `unpause()`
- `withdraw()`
- `getReward()`
- `exit()`

### What Could Break It
- whitelist removal after user has already staked
- pause state preventing recovery indefinitely
- mismatch between operational controls and user expectations

---

## 9. Reclaim should not silently invalidate outstanding user reward expectations without explicit shutdown semantics
### Statement
If `reclaim()` is used, the effect on existing accrued rewards and unclaimed user expectations must be clear and internally consistent.

### Why It Matters
`reclaim()` sets:
- `rewardsAvailableDate = block.timestamp`
- `targetRewardApy = 0`
- `rewardRate = 0`

and transfers all reward tokens to the owner.

This can effectively shut the system down and may leave previously accrued rewards unpaid.

### Relevant Flows
- `reclaim()`
- `getReward()`
- `earned()`
- `updateReward(account)`

### What Could Break It
- users retaining accounting claims but no actual reward-token backing
- ambiguous shutdown semantics
- inconsistency between stored `rewards[account]` and actual funded balance

---

## 10. Reward accounting should remain consistent under FSR transfers
### Statement
If FSR shares are transferable, transferring them should not create incorrect reward attribution between sender and receiver.

### Why It Matters
Since reward accounting depends on share balance, transfers are economically meaningful and must settle reward state correctly for both sides.

### Relevant Flows
- `_update(address from, address to, uint256 value)`
- `earned(account)`
- `userRewardPerTokenPaid`
- `rewards[account]`

### What Could Break It
- failing to checkpoint both sender and receiver before balance movement
- unexpected reward capture through transfer timing
- reward debt/state not following intended ownership model

---

## 11. Zero-supply periods should not create invalid reward jumps
### Statement
When `totalSupply() == 0`, the global reward state should remain well-defined and should not create unfair reward jumps when staking resumes.

### Why It Matters
Reward systems often behave differently when no one is staked. The transition from zero supply to nonzero supply is a common edge case.

### Relevant Flows
- `rewardPerToken()`
- `stake()`
- `setRewardYieldForYear()`
- `rebalance()`

### What Could Break It
- reward accumulation during zero-supply periods being applied unexpectedly
- incorrect assumptions around `rewardPerTokenStored`
- unfair first-staker advantage after long idle periods

---

## 12. Admin recovery of arbitrary ERC20 should not violate intended obligations to users
### Statement
Recovery functions should not remove tokens that are needed to satisfy active user claims unless explicitly intended and disclosed by system policy.

### Why It Matters
`recoverERC20()` forbids withdrawing the staking token, but it allows recovering other tokens, including potentially the reward token.

### Relevant Flows
- `recoverERC20()`
- `getReward()`
- reward funding assumptions

### What Could Break It
- owner draining reward token via recovery while users still have accrued but unpaid rewards
- mismatch between accounting promises and actual token reserves