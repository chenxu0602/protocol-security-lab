# Function Notes

## Conversion Layer

### rewardPerToken()
- calcuate the reward per token til lastUpdateTime

### earned(address account)
- calculate the earn tokens per account

### getRewardForDuration()
- reward rate times 14 day


## Entry Layer

### stake(uint256 amount)
- stake a positive amount of staking token
- required rewards have to be less than the balance of the pool

## Exit Layer
### withdraw(uint256 amount)
- withdraw the staking token

### getReward()
- get the reward token

### exit()
- withdraw and get reward


## Rebalance Layer
### _rebalance()
- get current reward token rate from aggregator
- calculate reward rate from APY