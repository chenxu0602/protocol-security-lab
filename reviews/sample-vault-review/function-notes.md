# Function Notes

## deposit()
- Accepts ETH
- Rejects zero deposit
- Increases user balance
- Increases totalAssets

## withdraw(uint256 amount)
- Rejects zero withdraw
- Checks user has enough balance
- Decreases accounting first
- Transfers ETH after state update
- Reentrancy should be considered even though state is updated first
