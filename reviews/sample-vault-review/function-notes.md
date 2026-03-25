# Function Notes

## deposit()
- Accepts ETH
- Rejects zero deposit
- Increases `balanceOf[msg.sender]`
- Increases `totalAssets`
- No external calls

## withdraw(uint256 amount)
- Rejects zero withdraw
- Requires sufficient recorded balance
- Decreases accounting before external interaction
- Sends ETH to caller using `call`
- Uses CEI ordering, so classic same-function reentrancy drain is not obvious
- Transfer failure reverts the whole transaction



---

# Then update your notes
In `reviews/sample-vault-review/function-notes.md`, add a sharper note for `withdraw()`:

```md
## withdraw(uint256 amount)
- Safe version should follow CEI: checks → effects → interactions
- If ETH is transferred before state update, reentrant re-entry can allow over-withdrawal
- Core property: user must not extract more than recorded balance