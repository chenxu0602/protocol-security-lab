# Threat Model

## Protocol Summary
Yearn V3 Tokenized Strategy is an ERC-4626 single-strategy vault framework where each deployed strategy delegates standardized ERC20, ERC4626, permit, accounting, fee, and profit-unlock logic to a shared `TokenizedStrategy` implementation through `delegatecall`.

## Main Actors / Roles
- Depositor / Shareholder
- Withdrawer / Redeemer
- Strategy management
- Keeper
- Emergency admin
- Performance fee recipient
- Protocol fee recipient
- Strategy implementation inherited from `BaseStrategy`
- Shared `TokenizedStrategy` implementation
- External yield source(s)
- Underlying asset token

## Assumed Trusted
- The shared `TokenizedStrategy` implementation is correct and deployed at the expected constant address
- The strategy is intentionally built on top of the expected `BaseStrategy` / fallback / `delegatecall` pattern
- The underlying asset behaves close enough to a standard ERC20 for transfer and balance-based accounting to remain meaningful
- No unexpected storage collision exists between strategy-specific storage and the `StrategyData` storage slot used by `TokenizedStrategy`

## Must Be Verified
- Strategy-specific callback logic such as `_deployFunds()`, `_freeFunds()`, `_harvestAndReport()`, and optional limits preserves coherent accounting
- `report()` inputs from strategy code cannot make profit, loss, or fee realization economically misleading or surprising
- Factory fee configuration interacts with fee minting in a way that matches expected user dilution and does not create hidden accounting surprises
- Withdraw / redeem semantics under shortfall remain coherent and respect documented `maxLoss` behavior

## Privileged Roles
- `management` can set keeper, emergency admin, fee recipient, performance fee, profit unlock period, and pending management
- `pendingManagement` can accept management
- `keeper` can call `report()` and `tend()`
- `emergencyAdmin` can shutdown the strategy and call emergency paths alongside management
- Factory governance controls protocol fee bps and protocol fee recipient

## External Dependencies
- Underlying ERC20 asset behavior
- External yield source integrations implemented by the concrete strategy
- Factory fee configuration via `protocol_fee_config()`
- `delegatecall` from strategy fallback into the shared implementation
- Timestamp-based profit unlocking behavior

## Accounting Anchor
- The accounting anchor is not raw token balance alone
- User pricing depends on stored `totalAssets`, current total share supply, locked-profit state, fee-share minting, and the latest report-driven realization of profit or loss
- Direct token donations, unrealized gains or losses in external positions, and pending unlock state can make on-chain balances diverge from the accounting state users trade against
- `totalAssets` is a key user-facing pricing anchor, but it must be interpreted together with report cadence and profit unlocking state

## Fund Flows
- Assets enter through `deposit()` and `mint()`
- Assets may move from idle balance into an external yield source through strategy deployment callbacks
- Assets leave external positions through strategy free-funds / emergency-withdraw callbacks
- Assets leave the strategy through `withdraw()` and `redeem()`
- Shares are minted to depositors and may also be minted as fee shares during `report()`
- Locked profit is represented through accounting and unlocks over time rather than immediate free distribution

## Core State Transitions
- `deposit()` / `mint()` transfers assets in, mints shares, and may deploy idle funds through the strategy callback
- `withdraw()` / `redeem()` burns shares, may trigger `_freeFunds()`, and can realize losses subject to liquidity and `maxLoss`
- `report()` harvests current strategy value, realizes profit or loss, charges fees, updates `totalAssets`, and resets profit-unlock state
- `tend()` may deploy idle funds or perform maintenance without changing high-level accounting in unintended ways
- `shutdownStrategy()` permanently disables new deposits and mints while preserving exits and reporting
- `emergencyWithdraw()` should move funds from external positions back to idle without corrupting accounting
- Management handoff changes privileged control through a two-step transition

## Core Invariants
- Share issuance and burn paths should remain economically coherent with the current accounting state
- `totalAssets` should track the strategy’s intended accounting anchor rather than raw token balance alone
- Preview functions should match execution when state is unchanged and only diverge for explainable state transitions
- Profit, loss, and fee realization should not create unexplained value transfer between early and late users
- Locked profit should unlock monotonically over time and should not make PPS move in an unintuitive direction
- Loss handling on withdraw / redeem should respect documented `maxLoss` semantics
- Shutdown should block new entries without preventing fair exits
- Privileged actions should not let roles directly seize depositor funds unless the concrete strategy itself is written to permit that

## Economic Risk Questions
- Can late depositors buy into profit that has already been earned but not yet fully distributed at an unfairly cheap price?
- Can report timing or keeper / management cadence shift value between early users, late users, and fee recipients?
- Can fee-share minting or profit unlock timing create unintuitive price-per-share behavior even when the code is functioning as designed?
- Can withdraw and redeem paths under loss produce path-dependent or user-dependent outcomes that are economically surprising?
- Can preview values become misleading around report, unlock, fee, or loss boundaries even when execution is technically correct?

## Potential Attack Surfaces
- Storage collision or delegatecall context mistakes between `BaseStrategy`, `TokenizedStrategy`, and concrete strategy storage
- Misreporting in `_harvestAndReport()` causing false profit, false loss, or fee misassessment
- Manipulation of `_freeFunds()` outcomes leading to surprising withdraw loss realization
- Share dilution or unfair pricing around profit report, fee minting, and profit unlock boundaries
- Preview / execution mismatch after report, unlock progression, or loss realization
- Permissionless deposit / withdraw timing around strategy callbacks that interact with external markets
- Keeper or management abuse of reporting cadence to change who benefits from unlocked profit
- Factory fee configuration affecting fee split in ways users may not anticipate
- Non-standard ERC20 behavior, donations, or direct asset transfers causing accounting edge cases
