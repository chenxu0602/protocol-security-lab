# Function Notes

## Architecture Layer

### `BaseStrategy.fallback()`
- Any function not implemented in the concrete strategy is forwarded by `delegatecall` to the shared `TokenizedStrategy`
- All accounting and ERC4626 state therefore lives in the strategy storage, but logic executes from the shared implementation
- Review consequence: storage layout assumptions and callback trust are central, not incidental

### `BaseStrategy._delegateCall(bytes)`
- Used during construction to initialize strategy storage through the shared implementation
- Re-bubbles revert data from the implementation
- Any strategist use of this helper expands the review surface because it can reach arbitrary `TokenizedStrategy` entrypoints

### `TokenizedStrategy.initialize(...)`
- One-time initializer guarded by `S.asset == address(0)`
- Sets asset, decimals, name, default fee config, default unlock period, and initial privileged roles
- Rejects zero fee recipient and rejects fee recipient equal to `address(this)` to avoid burning / self-locking fee shares
- Establishes the initial accounting baseline: `totalAssets` starts at zero and `lastReport` starts at current timestamp

## Access Control / Trust Layer

### `requireManagement(address)`
- Checks the supplied sender matches stored `management`
- BaseStrategy modifiers route original caller authority through this helper

### `requireKeeperOrManagement(address)`
- Allows only `keeper` or `management`
- Critical because `report()` and `tend()` sit behind this gate

### `requireEmergencyAuthorized(address)`
- Allows only `management` or `emergencyAdmin`
- Governs irreversible shutdown and emergency withdraw flow

## Accounting Anchor

### `totalAssets()`
- Returns stored `S.totalAssets`, not live token balance
- This is a deliberate anti-donation / anti-balance-manipulation choice
- Main implication: user pricing follows the last reported accounting state, not necessarily current economic reality

### `totalSupply()`
- Returns `S.totalSupply - _unlockedShares(S)`
- Locked profit shares held by the strategy are excluded from circulating supply as they unlock over time
- This is a core pricing mechanism, not a cosmetic supply adjustment

### `_unlockedShares(StrategyData)`
- Unlocks strategy-held shares linearly from `lastReport` to `fullProfitUnlockDate`
- If unlock date has passed, all remaining strategy-held locked shares count as unlocked
- This directly changes effective supply over time and therefore changes PPS without any transfer or report occurring

### `balanceOf(address)`
- Special-cases `address(this)` to subtract already unlocked shares from the strategy’s own balance
- Prevents strategy-held locked shares from appearing fully spendable while they are being amortized into PPS

### `pricePerShare()`
- Uses `convertToAssets(10 ** decimals)` with floor rounding
- Good for rough user-facing pricing, but exact reasoning should use conversion helpers

## Conversion Layer

### `_convertToShares(assets, rounding)`
- Uses effective supply from `_totalSupply()` and stored `totalAssets`
- Returns 1:1 when effective supply is zero
- Returns zero if assets are nonzero while effective supply exists but `totalAssets == 0`
- Profit unlock affects this conversion through supply, even when `totalAssets` is unchanged

### `_convertToAssets(shares, rounding)`
- Uses stored `totalAssets` over effective supply
- Returns 1:1 when effective supply is zero
- This is the core exit-side accounting conversion

### `previewDeposit()`
- Same formula as `convertToShares` with floor rounding
- Intended to match same-state `deposit()`

### `previewMint()`
- Uses `convertToAssets` with ceil rounding
- User must bring enough assets to receive exact target shares

### `previewWithdraw()`
- Uses `convertToShares` with ceil rounding
- Overestimates shares burned relative to exact division, which is standard for safe withdraw previews

### `previewRedeem()`
- Uses `convertToAssets` with floor rounding
- Same-state match target for `redeem()`, subject to later loss realization in execution paths

## Entry Layer

### `_maxDeposit(receiver)`
- Returns zero if the strategy is shutdown or if receiver is the strategy itself
- Otherwise delegates limit logic to `BaseStrategy.availableDepositLimit(receiver)`
- Review focus: custom strategist limits can change who may enter and when

### `_maxMint(receiver)`
- Same shutdown / self restrictions as `_maxDeposit`
- Converts deposit-limit assets into shares using floor rounding when the limit is finite
- Finite strategist asset limits can therefore translate into share-side rounding edge cases

### `BaseStrategy.availableDepositLimit(address)`
- Defaults to `uint256.max`
- Intended strategist hook for whitelist, cap, or permissioning logic
- Important because deposit and mint paths trust this hook as the entry guard

### `deposit(uint256 assets, address receiver)`
- If `assets == type(uint256).max`, pulls full sender asset balance
- Checks against `_maxDeposit`
- Converts assets to shares with floor rounding and rejects zero-share deposits
- Calls `_deposit`

### `mint(uint256 shares, address receiver)`
- Checks against `_maxMint`
- Converts requested shares to assets with ceil rounding and rejects zero-asset mints
- Calls `_deposit`

### `_deposit(...)`
- Transfers assets in before minting shares
- Calls `deployFunds()` with the full loose asset balance after transfer, not just the newly supplied amount
- Only after external deployment callback returns does it increase `S.totalAssets` by `assets`
- Then mints shares to the receiver
- Review focus:
- Deposit pricing is based on pre-deposit accounting state
- Strategy callback can move funds before accounting update
- Design intentionally avoids raw-balance donation manipulation by updating `totalAssets` manually

### `BaseStrategy.deployFunds(uint256)` / `_deployFunds(uint256)`
- External callback can only be entered through `onlySelf`
- Concrete strategy chooses how much of the provided loose balance to deploy
- Since deposit is permissionless by default, strategist implementation may be sandwich-sensitive or market-manipulable

## Exit Layer

### `_maxWithdraw(owner)`
- Starts from strategist-provided `availableWithdrawLimit(owner)`
- If unlimited, returns the owner’s full asset claim via `convertToAssets(balanceOf(owner))`
- If limited, returns the minimum of economic claim and strategist limit
- This is an important distinction: withdrawability is bounded by both ownership and strategy-imposed liquidity constraints

### `_maxRedeem(owner)`
- Also starts from strategist `availableWithdrawLimit(owner)`
- If unlimited, returns full share balance
- If limited, converts that asset-side limit back into shares with floor rounding, then caps by actual balance
- Withdraw and redeem limits are therefore related but not identical in shape

### `BaseStrategy.availableWithdrawLimit(address)`
- Defaults to `uint256.max`
- Strategists can use it to model illiquidity, delayed exits, or anti-sandwich constraints
- Review focus: this hook is a major source of path dependence for exits

### `withdraw(assets, receiver, owner[, maxLoss])`
- Public overload defaults `maxLoss = 0`, so plain withdraw tolerates no loss
- Requires `assets <= _maxWithdraw(owner)`
- Computes shares to burn using ceil rounding before actual free-funds outcome is known
- Passes both target assets and computed shares into `_withdraw`

### `redeem(shares, receiver, owner[, maxLoss])`
- Public overload defaults `maxLoss = MAX_BPS`, so plain redeem allows full loss realization
- Requires `shares <= _maxRedeem(owner)`
- Computes expected assets using floor rounding before actual free-funds outcome is known
- Returns actual assets received from `_withdraw`

### `_withdraw(...)`
- Validates receiver and `maxLoss`
- Spends allowance when caller is not owner
- Reads current idle balance first
- If idle is insufficient, calls `freeFunds(assets - idle)` on the strategy
- Re-reads idle after callback and treats any shortfall as `loss`
- If `maxLoss < MAX_BPS`, reverts when realized loss exceeds tolerance
- Reduces `S.totalAssets` by `assets + loss`, which equals the originally requested claim before any haircut
- Burns the precomputed number of shares, then transfers actual assets out
- Review focus:
- Loss realization is path-sensitive because share burn amount is fixed before actual shortfall is known
- `withdraw` and `redeem` have materially different default loss tolerance
- Strategy `_freeFunds()` behavior directly shapes user outcomes

### `BaseStrategy.freeFunds(uint256)` / `_freeFunds(uint256)`
- External callback can only be entered through `onlySelf`
- Concrete strategy decides how much capital can actually be freed
- Any under-delivery is socialized immediately into the caller’s exit path as realized loss

## Reporting / Profit Locking Layer

### `report()`
- Restricted to keeper or management
- Calls strategy `harvestAndReport()` to get the new asset value anchor
- Compares `newTotalAssets` against stored `oldTotalAssets`
- Realizes either profit or loss at report time rather than continuously
- Profit path:
- Computes profit in assets
- Converts profit to shares at pre-mint / pre-burn PPS
- Charges performance fees in shares
- Pulls protocol fee configuration from factory and splits fee shares between protocol and performance fee recipient
- Locks net-of-fee profit by minting shares to the strategy or offsets prior locked shares by burning
- Loss path:
- Computes loss in assets
- Attempts to offset PPS damage by burning unlocked and still-locked strategy-held shares up to available amount
- Recomputes weighted-average unlock period for any remaining locked shares
- Updates `S.totalAssets` to `newTotalAssets` and sets `lastReport = block.timestamp`
- Review focus:
- `harvestAndReport()` is the accounting trust anchor for economic state changes
- Fee minting dilutes users before or alongside profit locking
- Report cadence changes when profits become visible in PPS
- Losses can be cushioned by burning locked shares, which changes who absorbs pain and when

### `BaseStrategy.harvestAndReport()` / `_harvestAndReport()`
- External callback can only be entered through `onlySelf`
- Concrete strategy must return the full current asset value under control, including idle assets
- Most important strategist hook for this review because every profit / loss / fee / unlock sequence depends on it being economically honest

### `unlockedShares()`
- Public view surface for observing progress of locked-profit amortization
- Useful for tests around PPS drift between reports

### `setProfitMaxUnlockTime(uint256)`
- Management-only
- Caps unlock horizon to one year
- Setting value to zero burns all currently locked strategy-held shares and zeroes unlock variables
- This can cause immediate full profit realization into PPS, so timing matters economically

## Tending / Shutdown Layer

### `tend()`
- Restricted to keeper or management
- Passes current loose balance to `tendThis()`
- Intended not to change PPS directly because it should not change `totalAssets`
- Still worth testing because strategist `_tend()` can change actual economic state before the next report

### `BaseStrategy.tendThis(uint256)` / `_tend(uint256)`
- Optional strategist maintenance hook
- Can deploy idle funds or perform non-report upkeep
- Trust boundary: should not silently create accounting assumptions that only become visible later

### `shutdownStrategy()`
- Callable by management or emergency admin
- One-way switch that blocks future deposit / mint through `_maxDeposit` and `_maxMint`
- Does not block withdraw, redeem, report, or tend

### `emergencyWithdraw(uint256)`
- Requires prior shutdown
- Calls strategist `shutdownWithdraw(amount)`
- Intended to move funds from external positions back to idle without directly changing PPS
- A later `report()` is still needed to realize any profit or loss caused by the emergency unwind

### `BaseStrategy.shutdownWithdraw(uint256)` / `_emergencyWithdraw(uint256)`
- Optional strategist emergency callback
- Should free assets without immediately redefining accounting; report remains the realization point

## Management Layer

### `setPendingManagement()` / `acceptManagement()`
- Two-step management transfer
- Changes the address controlling economic parameters and operational roles

### `setKeeper()`
- Changes who can decide report cadence and tend cadence
- This is economically relevant because timing affects profit visibility and unlock progression

### `setEmergencyAdmin()`
- Extends shutdown and emergency-withdraw authority

### `setPerformanceFee(uint16)`
- Management-only and capped by `MAX_FEE`
- Directly changes future fee-share dilution on profitable reports

### `setPerformanceFeeRecipient(address)`
- Cannot be zero and cannot be the strategy itself
- Changes who captures fee-share dilution

### `setName(string)`
- Metadata-only from an accounting perspective
