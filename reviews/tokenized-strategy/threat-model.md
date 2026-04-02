# Threat Model

## Protocol Summary
Yearn V3 Tokenized Strategy is a single-strategy ERC-4626 framework where each deployed strategy delegates standardized ERC20, ERC4626, fee, and profit-unlock logic to a shared `TokenizedStrategy` implementation via `delegatecall`.

## Actors
- Depositor / shareholder
- Withdrawer / redeemer
- Strategy management
- Keeper
- Emergency admin
- Performance fee recipient
- Protocol fee recipient
- Concrete strategy implementation
- Shared `TokenizedStrategy` implementation
- Underlying asset token
- External yield source

## Trust Assumptions
- The shared `TokenizedStrategy` implementation is correct and deployed at the expected constant address
- The strategy follows the intended `BaseStrategy` + fallback + `delegatecall` architecture
- The underlying asset is close enough to a standard ERC20 for transfers and balance reads to be meaningful
- There is no storage collision between strategy-specific storage and the `StrategyData` storage slot

## Callback Boundary
- `_deployFunds()` is the strategy-controlled capital deployment hook used after deposits and mints
- `_freeFunds()` is the strategy-controlled liquidity hook used during withdraw and redeem
- `_harvestAndReport()` is the strategy-controlled valuation hook used by `report()` to set the asset accounting anchor
- `_tend()` and `_emergencyWithdraw()` are operational hooks that should move funds or maintain positions without silently breaking accounting assumptions
- These callbacks are the main honesty boundary of the system: the shared logic is standardized, but the strategy decides how asset value and liquidity are exposed to it

## Accounting Anchors
- The main accounting anchor is stored `totalAssets`, not raw token balance
- User pricing depends on stored `totalAssets`, effective `totalSupply`, locked-profit shares held by the strategy, and fee-share minting during `report()`
- Profit unlock changes effective circulating supply over time even when `totalAssets` does not change
- Direct donations, unrealized PnL in external positions, and delayed reporting can make live balances diverge from the accounting state users actually trade against

## Economic Risk Questions
- Can late depositors buy into previously earned but not yet unlocked profit too cheaply?
- Can report cadence shift value between existing users, new users, and fee recipients?
- Can fee-share minting create more dilution than the intended economics imply?
- Can `_freeFunds()` shortfalls make withdraw and redeem outcomes path-dependent in surprising ways?
- Can preview results become misleading around report, unlock, fee, or loss boundaries?
- Can emergency or tending flows change liquidity location without preserving the intended accounting model?

## Main Review Focus
- Entry pricing under stored accounting rather than live balances
- Exit pricing and loss realization under `_freeFunds()` shortfall
- `report()`-driven profit, loss, fee, and locked-profit transitions
- Time-based unlock behavior and its effect on PPS and user fairness
- Whether strategist callbacks preserve coherent accounting under benign and adversarial sequencing
