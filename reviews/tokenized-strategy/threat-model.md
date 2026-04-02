# Threat Model

## Protocol Summary
Yearn V3 Tokenized Strategy is a single-strategy ERC-4626 framework in which each deployed strategy delegates standardized ERC20, ERC4626, fee, and profit-unlock logic to a shared `TokenizedStrategy` implementation via `delegatecall`.

The shared layer standardizes accounting mechanics, but each concrete strategy remains responsible for exposing truthful asset value and liquidity through its strategy callbacks.

## Actors
- Incumbent depositor / existing shareholder
- Late depositor / new entrant
- Withdrawer / redeemer
- Strategist / strategy management
- Keeper
- Emergency admin
- Performance fee recipient
- Protocol fee recipient
- Concrete strategy implementation
- Shared `TokenizedStrategy` implementation
- Underlying asset token
- External yield source / venue

## Trust Assumptions
- The shared `TokenizedStrategy` implementation is correct and deployed at the expected constant address
- The strategy follows the intended `BaseStrategy` + fallback + `delegatecall` architecture
- The underlying asset behaves close enough to a standard ERC20 for balances and transfers to remain meaningful
- There is no storage collision between strategy-specific storage and the namespaced `StrategyData` storage slot
- Reported valuation is only as reliable as the concrete strategy’s implementation of `_harvestAndReport()`, including how it accounts for idle funds, deployed funds, pending rewards, unrealized gains, and unrealized losses

## Callback Boundary
- `_deployFunds()` is the strategy-controlled deployment hook used after deposits and mints
- `_freeFunds()` is the strategy-controlled liquidity hook used during withdraw and redeem
- `_harvestAndReport()` is the strategy-controlled valuation hook used by `report()` to set the accounting anchor
- `_tend()` and `_emergencyWithdraw()` are operational hooks that may move funds or positions without necessarily updating stored accounting immediately
- These callbacks are the primary honesty boundary of the system: the shared accounting logic is standardized, but the strategy determines how value and liquidity are surfaced to it

## Accounting Anchors
- The main accounting anchor is stored `totalAssets`, not raw token balance
- User pricing depends on stored `totalAssets`, effective `totalSupply`, locked-profit shares held by the strategy, and fee-share minting during `report()`
- Profit unlock changes effective circulating supply over time even when stored `totalAssets` does not change
- Direct donations, unrealized PnL, stale reporting, or delayed realization can make live economic value diverge from the accounting state against which users transact

## Main Economic Risk Questions
- Can late entrants buy into previously earned but not yet reported or not yet unlocked value too cheaply?
- Can over-reporting or optimistic valuation overcharge entrants and over-mint fee shares?
- Can reported asset value diverge materially from realizable exit value, causing profits, fees, or user claims to be recognized before liquidation risk is actually borne?
- Can report cadence shift value between incumbents, late entrants, and fee recipients even on the same economic path?
- Can `_freeFunds()` shortfalls make withdraw and redeem outcomes path-dependent in surprising or unfair ways?
- Can preview functions become misleading around report, unlock, fee, or loss boundaries?
- Can tending or emergency flows relocate liquidity without preserving the intended accounting model?

## Main Review Surfaces

### Entry Surface
- Deposits and mints price against stored accounting rather than necessarily fresh realizable value
- Entry fairness depends on report freshness, unlock state, and the integrity of callback valuation

### Exit Surface
- Withdraws and redeems depend on `_freeFunds()` and may realize losses only when capital is actually sourced
- Exit outcomes may therefore differ from previously reported accounting

### Report Surface
- `report()` crystallizes profit/loss, mints fee shares, mints or updates locked-profit shares, and resets unlock state
- Misreporting or mistiming at this boundary can permanently alter allocation outcomes

### Time Surface
- Unlock changes effective supply over time even without new economic activity
- Keeper/report cadence is therefore an allocation mechanism, not merely an operational detail