# Function Notes

## Architecture Layer

### `BaseStrategy.fallback()`
- Any function not implemented in the concrete strategy is forwarded by `delegatecall` to the shared `TokenizedStrategy`.
- ERC20, ERC4626, fee, and profit-unlock logic therefore execute from the shared implementation while state lives in the concrete strategy’s storage context.
- Review implication: storage layout assumptions and callback trust are central to correctness, not incidental details.

### `BaseStrategy._delegateCall(bytes)`
- Used during construction to initialize strategy storage through the shared implementation.
- Re-bubbles revert data from the implementation.
- Any strategist-controlled use of this helper expands the reachable surface because it can invoke arbitrary `TokenizedStrategy` entrypoints in the current strategy storage context.

### `TokenizedStrategy.initialize(...)`
- One-time initializer guarded by `S.asset == address(0)`.
- Sets asset, decimals, name, fee configuration, default unlock period, and initial privileged roles.
- Rejects zero fee recipient and rejects fee recipient equal to `address(this)` to avoid burning or self-locking fee shares.
- Establishes the initial accounting baseline: `totalAssets` starts at zero and `lastReport` starts at the current timestamp.

## Access Control / Trust Layer

### `requireManagement(address)`
- Checks that the supplied sender matches stored `management`.
- `BaseStrategy` modifiers route original caller authority through this helper.

### `requireKeeperOrManagement(address)`
- Allows only `keeper` or `management`.
- Economically important because `report()` and `tend()` sit behind this gate.

### `requireEmergencyAuthorized(address)`
- Allows only `management` or `emergencyAdmin`.
- Governs shutdown and emergency-withdraw flows.

## Accounting Anchors

### `totalAssets()`
- Returns stored `S.totalAssets`, not the live token balance.
- This is a deliberate anti-donation / anti-balance-manipulation choice.
- Main implication: user pricing follows the last reported accounting state, not necessarily the freshest realizable economic value.
- In practice, report freshness is therefore more important to entry fairness than raw balance visibility alone.

### `totalSupply()` / effective circulating supply
- Public supply is adjusted by subtracting already unlocked strategy-held locked shares.
- This means supply is not just a raw share counter; it is part of the pricing mechanism.
- Profit unlock can therefore change effective circulating supply over time even when stored `totalAssets` does not change.

### `_unlockedShares(StrategyData)`
- Unlocks strategy-held locked shares linearly from `lastReport` to `fullProfitUnlockDate`.
- If the unlock date has passed, all remaining strategy-held locked shares count as unlocked.
- This changes effective supply over time and therefore changes PPS without requiring a new transfer or a new report.

### `balanceOf(address)`
- Special-cases `address(this)` to subtract already unlocked shares from the strategy’s own balance.
- This prevents strategy-held locked shares from appearing fully spendable while they are being amortized into PPS.
- Ordinary user balances do not use this special-case treatment.

### `pricePerShare()`
- Uses `convertToAssets(10 ** decimals)` with floor rounding.
- Useful as a rough user-facing price indicator, but exact reasoning should rely on the conversion helpers directly.

## Conversion Layer

### `_convertToShares(assets, rounding)`
- Uses stored `totalAssets` and effective supply rather than raw balances.
- Returns `1:1` when effective supply is zero.
- Returns zero if assets are nonzero while effective supply exists but `totalAssets == 0`.
- Profit unlock can affect this conversion through supply decay even when `totalAssets` is unchanged.

### `_convertToAssets(shares, rounding)`
- Uses stored `totalAssets` over effective supply.
- Returns `1:1` when effective supply is zero.
- This is the core accounting conversion for translating share claims back into assets.

### `previewDeposit()`
- Uses the same share-conversion path as `deposit()` with floor rounding.
- Intended to match same-state `deposit()`.

### `previewMint()`
- Uses asset conversion with ceil rounding.
- The user must provide enough assets to receive the exact target shares.

### `previewWithdraw()`
- Uses share conversion with ceil rounding.
- Standard conservative preview shape for withdraw-side share burn estimation.

### `previewRedeem()`
- Uses asset conversion with floor rounding.
- Intended to match same-state `redeem()`, subject to later execution-side liquidity or loss realization.

## Entry Layer

### `_maxDeposit(receiver)`
- Returns zero if the strategy is shutdown or if the receiver is the strategy itself.
- Otherwise delegates entry-limit logic to `BaseStrategy.availableDepositLimit(receiver)`.
- Review focus: custom strategist limits can change who may enter and when.

### `_maxMint(receiver)`
- Same shutdown and self restrictions as `_maxDeposit`.
- Converts deposit-limit assets into shares using floor rounding when the limit is finite.
- Finite strategist asset limits can therefore create share-side rounding edge cases.

### `BaseStrategy.availableDepositLimit(address)`
- Defaults to `uint256.max`.
- Intended strategist hook for whitelist, cap, or permissioning logic.
- Important because deposit and mint paths trust this hook as the entry guard.

### `deposit(uint256 assets, address receiver)`
- If `assets == type(uint256).max`, pulls the sender’s full asset balance.
- Checks against `_maxDeposit`.
- Converts assets to shares with floor rounding and rejects zero-share deposits.
- Calls `_deposit`.

### `mint(uint256 shares, address receiver)`
- Checks against `_maxMint`.
- Converts requested shares to assets with ceil rounding and rejects zero-asset mints.
- Calls `_deposit`.

### `_deposit(...)`
- Transfers assets in before minting shares.
- Calls `deployFunds()` with the full loose asset balance after transfer, not just the newly supplied amount.
- Only after the external deployment callback returns does it increase `S.totalAssets` by `assets`.
- Then mints shares to the receiver.

**Review focus**
- Deposit pricing is based on the pre-deposit accounting state.
- The strategy callback can move funds before the stored accounting update.
- The design intentionally avoids raw-balance donation manipulation by updating `totalAssets` manually rather than inferring it from live balances.

### `BaseStrategy.deployFunds(uint256)` / `_deployFunds(uint256)`
- External callback can only be entered through `onlySelf`.
- The concrete strategy decides how much of the provided loose balance to deploy.
- Since deposit is permissionless by default, strategist implementation may still be sandwich-sensitive or execution-sensitive depending on where capital is deployed.

## Exit Layer

### `_maxWithdraw(owner)`
- Starts from strategist-provided `availableWithdrawLimit(owner)`.
- If unlimited, returns the owner’s full asset claim via `convertToAssets(balanceOf(owner))`.
- If limited, returns the minimum of the economic claim and the strategist limit.
- Withdrawability is therefore bounded by both ownership and strategy-imposed liquidity constraints.

### `_maxRedeem(owner)`
- Also starts from strategist `availableWithdrawLimit(owner)`.
- If unlimited, returns the full share balance.
- If limited, converts the asset-side limit back into shares with floor rounding, then caps by the actual balance.
- Withdraw and redeem limits are therefore related but not identical in shape.

### `BaseStrategy.availableWithdrawLimit(address)`
- Defaults to `uint256.max`.
- Strategists can use it to model illiquidity, delayed exits, or anti-sandwich constraints.
- Review implication: this hook is a major source of exit-side path dependence.

### `withdraw(assets, receiver, owner[, maxLoss])`
- Public overload defaults `maxLoss = 0`, so plain `withdraw()` tolerates no loss.
- Requires `assets <= _maxWithdraw(owner)`.
- Computes shares to burn using ceil rounding before the actual `freeFunds()` outcome is known.
- Passes both target assets and computed shares into `_withdraw`.

### `redeem(shares, receiver, owner[, maxLoss])`
- Public overload defaults `maxLoss = MAX_BPS`, so plain `redeem()` allows full loss realization.
- Requires `shares <= _maxRedeem(owner)`.
- Computes expected assets using floor rounding before the actual `freeFunds()` outcome is known.
- Returns the actual assets received from `_withdraw`.

### `_withdraw(...)`
- Validates receiver and `maxLoss`.
- Spends allowance when the caller is not the owner.
- Reads current idle balance first.
- If idle is insufficient, calls `freeFunds(assets - idle)` on the strategy.
- Re-reads idle after the callback and treats any shortfall as `loss`.
- If `maxLoss < MAX_BPS`, reverts when realized loss exceeds tolerance.
- Reduces `S.totalAssets` by `assets + loss`, which matches the originally requested claim before any haircut.
- Burns the precomputed number of shares, then transfers actual assets out.

**Review focus**
- Shares are computed before the actual `freeFunds()` result is observed, so realized shortfall can make the final exit outcome differ from the pre-withdraw conversion path.
- `withdraw()` and `redeem()` have materially different default loss tolerance.
- Strategy `_freeFunds()` behavior directly shapes exit outcomes.

### `BaseStrategy.freeFunds(uint256)` / `_freeFunds(uint256)`
- External callback can only be entered through `onlySelf`.
- The concrete strategy decides how much capital can actually be freed.
- Any under-delivery is realized immediately in the caller’s exit path as loss.

## Reporting / Profit Locking Layer

### `report()`
- Restricted to keeper or management.
- Calls strategy `harvestAndReport()` to obtain the new asset-value anchor.
- Compares `newTotalAssets` against stored `oldTotalAssets`.
- Realizes profit or loss at report time rather than continuously.

**Profit path**
- Computes profit in assets.
- Converts profit to shares at the pre-adjustment PPS.
- Charges performance fees in shares.
- Pulls protocol fee configuration from the factory and splits fee shares between protocol and performance fee recipient.
- Locks net-of-fee profit by minting shares to the strategy or by offsetting prior locked shares where applicable.

**Loss path**
- Computes loss in assets.
- Attempts to offset PPS damage by burning strategy-held locked shares up to the available amount.
- Recomputes the unlock schedule for any remaining locked shares.

**State updates**
- Updates `S.totalAssets` to `newTotalAssets`.
- Sets `lastReport = block.timestamp`.

**Review focus**
- `harvestAndReport()` is the core accounting trust anchor for economic state changes.
- Fee minting can dilute users before or alongside profit locking.
- Report cadence changes when profits become visible in PPS.
- Locked-share burning on the loss path can materially affect how losses are reflected in PPS and across users.

### `BaseStrategy.harvestAndReport()` / `_harvestAndReport()`
- External callback can only be entered through `onlySelf`.
- The concrete strategy must return the full current asset value under control, including idle assets.
- This is the most important strategist hook for this review because every profit, loss, fee, and unlock transition depends on it being economically coherent.
- In practice, this callback acts as the valuation oracle for the accounting layer.

### `unlockedShares()`
- Public view surface for observing progress of locked-profit amortization.
- Useful for tests around PPS drift between reports.

### `setProfitMaxUnlockTime(uint256)`
- Management-only.
- Caps the unlock horizon to one year.
- Setting the value to zero burns all currently locked strategy-held shares and zeroes the unlock variables.
- This can force immediate full profit realization into PPS, so timing is economically relevant.

## Tending / Shutdown Layer

### `tend()`
- Restricted to keeper or management.
- Passes the current loose balance to `tendThis()`.
- Intended not to change PPS directly because it should not change stored `totalAssets`.
- Still worth testing because strategist `_tend()` can change actual economic state before the next report.

### `BaseStrategy.tendThis(uint256)` / `_tend(uint256)`
- Optional strategist maintenance hook.
- Can deploy idle funds or perform non-report upkeep.
- Trust boundary implication: it may change future accounting assumptions before those assumptions are crystallized by `report()`.

### `shutdownStrategy()`
- Callable by management or emergency admin.
- One-way switch that blocks future deposit and mint through `_maxDeposit` and `_maxMint`.
- Does not block withdraw, redeem, report, or tend.

### `emergencyWithdraw(uint256)`
- Requires prior shutdown.
- Calls strategist `shutdownWithdraw(amount)`.
- Intended to move funds from external positions back to idle without directly changing PPS.
- A later `report()` is still needed to realize any profit or loss caused by the emergency unwind.

### `BaseStrategy.shutdownWithdraw(uint256)` / `_emergencyWithdraw(uint256)`
- Optional strategist emergency callback.
- Should free assets without itself redefining accounting; `report()` remains the main realization point.

## Management Layer

### `setPendingManagement()` / `acceptManagement()`
- Two-step management transfer.
- Changes the address controlling economic parameters and operational roles.

### `setKeeper()`
- Changes who controls report cadence and tend cadence.
- In Yearn V3, timing authority is also partial allocation authority because report timing affects profit visibility and unlock progression.

### `setEmergencyAdmin()`
- Extends shutdown and emergency-withdraw authority.

### `setPerformanceFee(uint16)`
- Management-only and capped by `MAX_FEE`.
- Directly changes future fee-share dilution on profitable reports.

### `setPerformanceFeeRecipient(address)`
- Cannot be zero and cannot be the strategy itself.
- Changes who captures fee-share dilution.

### `setName(string)`
- Metadata-only from an accounting perspective.