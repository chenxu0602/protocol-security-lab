# Monetrix Accountant Notes

## 1. Purpose

`MonetrixAccountant` is the protocol's balance-sheet reader and yield gatekeeper.

Its two central responsibilities are:

1. Compute composite backing through `totalBackingSigned()`.
2. Bound keeper-reported yield through `settleDailyPnL(proposedYield)`.

The Accountant does not itself move funds. Fund movement happens in `MonetrixVault`.

The critical security question is:

```text
Can Accountant overstate distributable surplus?
```