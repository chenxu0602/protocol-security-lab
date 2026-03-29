# Issue Candidates

## Candidate 1: Removing a user from the whitelist may trap principal and accrued rewards
### Category
Access control / user-funds control surface

### Observation
`onlyWhitelisted` is applied not only to `stake()`, but also to:
- `withdraw()`
- `getReward()`
- `exit()`

If a user is removed from the whitelist after already staking, they may be unable to:
- withdraw principal
- claim already-accrued rewards
- use `exit()`

### Why It Matters
This is not just an entry restriction. It is an ongoing control over user access to funds and claims.

### Potential Impact
Users may become unable to recover principal or rewards after whitelist removal.

### Related Invariants
- Pause and whitelist state changes should not unintentionally trap principal or accrued rewards unless explicitly intended by design.
- A user’s accrued rewards should not decrease unexpectedly except through intended claim or shutdown logic.

### Status
Strong design-risk / policy-risk candidate.  
Needs confirmation whether this is explicitly intended behavior or an undesirable trapped-funds condition.

### How I Would Validate It
- Stake as a whitelisted user
- Accrue rewards
- Remove user from whitelist
- Attempt `withdraw()`, `getReward()`, and `exit()`
- Check whether funds/rewards are effectively trapped

---

## Candidate 2: `reclaim()` may zero future rewards while draining funded rewards needed for already-accrued claims
### Category
Admin / accounting / economic obligation

### Observation
`reclaim()`:
- sets `rewardsAvailableDate = block.timestamp`
- sets `targetRewardApy = 0`
- sets `rewardRate = 0`
- transfers all reward tokens to owner

This can leave users with:
- stored accrued rewards in accounting
- but no actual reward-token reserves in the contract

### Why It Matters
The contract may continue to reflect accrued claims in `rewards[account]` or through `earned(account)`, while reward-token backing has been removed.

### Potential Impact
Users may be unable to claim rewards that appear accrued in accounting.

### Related Invariants
- Reclaim should not silently invalidate outstanding user reward expectations without explicit shutdown semantics.
- Reward claims should not exceed the intended funded reward capacity under normal operation.

### Status
Strong candidate.  
May be intended emergency/admin shutdown behavior, but should be clearly documented and evaluated as a user-claim risk.

### How I Would Validate It
- Fund rewards
- Stake and accrue rewards
- Call `reclaim()`
- Check whether `earned(account)` or `rewards[account]` remains nonzero
- Attempt `getReward()` and observe whether claims can still be satisfied

---

## Candidate 3: `recoverERC20()` may allow owner to remove reward tokens needed to satisfy user claims
### Category
Admin / reward backing risk

### Observation
`recoverERC20()` prevents recovery of the staking token, but does not prevent recovery of the reward token.

### Why It Matters
If reward token recovery is allowed while users still have accrued but unpaid rewards, contract-side accounting may no longer match actual reserves.

### Potential Impact
Users may be left with reward claims that cannot be paid.

### Related Invariants
- Admin recovery of arbitrary ERC20 should not violate intended obligations to users.
- Reward claims should not exceed the intended funded reward capacity under normal operation.

### Status
Strong candidate.  
Likely an intended admin power, but economically/security relevant and worth explicit review.

### How I Would Validate It
- Supply rewards
- Let users accrue rewards
- Recover reward tokens as owner
- Attempt user claim
- Compare accounting state vs actual reserves

---

## Candidate 4: External self-call to `rebalance()` inside `withdraw()` introduces an unusual control-flow surface
### Category
Control flow / operational safety

### Observation
`withdraw()` does:

```solidity
try FixedStakingRewards(address(this)).rebalance() {} catch {}