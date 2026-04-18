# Function Notes

## Architecture / Entry Layer

### `Pool.supply()` / `supplyWithPermit()`
- External supply entrypoint.
- Flow:
  - cache reserve
  - `reserve.updateState()`
  - `ValidationLogic.validateSupply()`
  - `reserve.updateInterestRates(..., liquidityAdded = amount, liquidityTaken = 0)`
  - pull underlying into aToken
  - mint aTokens using `nextLiquidityIndex`
- First supply can auto-enable collateral through `validateAutomaticUseAsCollateral()`.
- Review focus:
  - supply-cap enforcement counts scaled supply plus `accruedToTreasury`
  - interest-rate update happens before token pull and aToken mint, so correctness relies on full transaction atomicity
  - isolated-collateral auto-enable depends on ACL role checks, not only reserve config

### `Pool.withdraw()`
- External redeem entrypoint.
- `type(uint256).max` withdraws full current balance computed from scaled balance times `nextLiquidityIndex`.
- If full balance is withdrawn, collateral flag is cleared before final HF/LTV validation.
- After aToken burn, `validateHFAndLtv()` re-checks solvency when user still has debt.
- Review focus:
  - scaled-balance to current-balance conversion is an accounting anchor
  - collateral bit flip happens before post-withdraw health check, so correctness relies on revert rollback
  - zero-LTV collateral positions have dedicated withdrawal/transfer restrictions via `validateHFAndLtv()`

### `Pool.borrow()`
- External debt-opening entrypoint.
- Delegates to `BorrowLogic.executeBorrow()` with oracle, eMode, isolation, and sentinel context.
- If `releaseUnderlying = true`, aToken transfers underlying to borrower after debt mint and rate update.
- Review focus:
  - solvency is checked against fresh account data before debt mint
  - stable borrow path has extra anti-self-collateral and max-loan-size checks
  - isolation and siloed borrowing are enforced here, not only at config time

### `Pool.repay()` / `repayWithPermit()` / `repayWithATokens()`
- External debt-closing entrypoints.
- `repayWithATokens()` burns aTokens instead of transferring underlying in.
- `type(uint256).max` is only allowed when repaying own debt; for aToken repay it resolves against caller aToken balance to avoid leaving dust.
- Review focus:
  - repay-with-underlying and repay-with-aTokens must stay economically aligned
  - repay closes debt-side accounting and separately settles asset-side accounting; both paths must remain economically equivalent
  - debt burn happens before underlying transfer / aToken burn, so safety relies on full transaction atomicity
  - isolation-mode total debt is decreased on repay through a separate side-accounting path

### `Pool.swapBorrowRateMode()`
- Switches existing debt between stable and variable modes.
- Burns one debt token type and mints the other against current indexes/rates.
- Review focus:
  - stable-enable and self-collateral abuse checks are inside `validateSwapRateMode()`
  - no asset movement occurs; correctness is pure debt-accounting integrity

### `Pool.rebalanceStableBorrowRate()`
- Adminless rebalance path for unhealthy stable-rate distribution scenarios.
- Re-mints stable debt at current reserve stable borrow rate.
- Review focus:
  - rebalance trigger depends on comparison between actual liquidity rate and synthetic variable-debt-only liquidity rate
  - this is an accounting/rate reset, not a liquidity event

### `Pool.setUserUseReserveAsCollateral()`
- Explicit collateral toggle entrypoint.
- Enabling is gated by LTV, isolation mode, and isolated-collateral rules.
- Disabling triggers health-factor validation under the new collateral set.
- Review focus:
  - `userConfig` bits are a first-class accounting surface
  - isolated assets cannot be casually mixed with other collateral modes

### `Pool.liquidationCall()`
- Permissionless unhealthy-position settlement path.
- Delegates to `LiquidationLogic.executeLiquidationCall()`.
- Review focus:
  - liquidation pricing depends on oracle, eMode price override, bonus, and protocol fee logic
  - close-factor regime switches at HF `0.95e18`
  - borrower config bits are mutated during liquidation and must stay aligned with actual remaining balances

### `Pool.flashLoan()` / `flashLoanSimple()`
- Atomic liquidity access path.
- Multi-asset `flashLoan()` can either repay normally or open debt for selected assets; `flashLoanSimple()` always requires repayment.
- Flow intentionally differs from normal cache-update-changeState ordering to reduce callback-side manipulation.
- Review focus:
  - fee waiver for authorized flash borrowers only applies to the multi-asset path
  - repayment path updates indices and treasury accrual before pulling funds back
  - debt-opening flash path routes into the same borrow validation/accounting as normal borrows

### `Pool.mintUnbacked()` / `backUnbacked()`
- Bridge-only privileged path.
- `mintUnbacked()` mints aTokens and increments reserve `unbacked` without transferring underlying.
- `backUnbacked()` later supplies underlying plus fee, reduces `unbacked`, and splits fee between LPs and treasury.
- Review focus:
  - reserve solvency temporarily relies on trusted bridge behavior
  - unbacked mint cap is an explicit exposure limit
  - fee accounting mirrors flashloan-style index accrual

### `Pool.getUserAccountData()`
- User-facing solvency view into `GenericLogic.calculateUserAccountData()`.
- Core output for collateral base value, debt base value, available borrows, LTV, liquidation threshold, and HF.
- Review focus:
  - any valuation drift here propagates into borrow, withdraw, liquidation, and UI behavior

---

## Supply / Transfer Layer

### `SupplyLogic.executeSupply()`
- Canonical supply implementation used by direct supply and permit supply.
- First supply may auto-mark collateral.
- Review focus:
  - mint uses `nextLiquidityIndex`, so stale-index mistakes would directly leak value
  - side-effect collateral enablement changes downstream borrowability immediately

### `SupplyLogic.executeWithdraw()`
- Canonical withdraw implementation.
- Burns aTokens to send underlying to `to`.
- Re-checks HF only after burn when user still borrows.
- Review focus:
  - order of collateral-bit clearing, burn, and HF validation is important
  - `type(uint256).max` path depends on exact scaled accounting

### `SupplyLogic.executeFinalizeTransfer()`
- Called by aToken transfer hooks.
- Prevents transfers that would violate sender solvency and can auto-enable collateral for receiver.
- Review focus:
  - aToken transfers are not pure ERC20 movement; they mutate protocol collateral state
  - sender and receiver `userConfig` bits can change as a side effect

### `SupplyLogic.executeUseReserveAsCollateral()`
- Shared implementation for explicit collateral toggle.
- Review focus:
  - must preserve consistency between actual aToken balances and `userConfig.isUsingAsCollateral`

---

## Borrow / Repay Layer

### `BorrowLogic.executeBorrow()`
- Loads reserve cache, updates state, reads user isolation-mode state, validates borrow, then mints debt.
- Stable path mints stable debt at `reserve.currentStableBorrowRate`; variable path mints scaled variable debt at `nextVariableBorrowIndex`.
- First borrow sets user borrowing bit for the reserve.
- If user is isolated, increments `isolationModeTotalDebt` in debt-ceiling units, not full token decimals.
- Review focus:
  - debt ceiling accounting is principal-like rather than live-interest-bearing debt accounting
  - variable and stable paths update different state components but converge on shared rate update and optional underlying release

### `BorrowLogic.executeRepay()`
- Reads fresh stable and variable debt, validates rate mode, bounds repay amount to outstanding debt, burns debt token, updates rates, then settles funds.
- Clears borrowing bit when total remaining debt on that reserve becomes zero.
- Calls `IsolationModeLogic.updateIsolatedDebtIfIsolated()`.
- Review focus:
  - repay semantics differ when assets come from underlying transfer vs aToken burn
  - debt-side accounting and asset-side settlement must remain economically coherent
  - full repay with aTokens intentionally resolves against actual aToken balance, not requested max amount
  - ordering is debt burn -> rate update -> fund settlement

### `BorrowLogic.executeSwapBorrowRateMode()`
- Stable-to-variable: burn stable debt then mint variable debt.
- Variable-to-stable: burn variable debt then mint stable debt at current stable rate.
- Review focus:
  - mode swap should not change net debt economically beyond allowed rounding/index effects

### `BorrowLogic.executeRebalanceStableBorrowRate()`
- Burns user stable debt and re-mints at current stable borrow rate when reserve conditions justify rebalance.
- Review focus:
  - reserve-level rate conditions, not borrower-specific behavior, determine reachability

---

## Liquidation Layer

### `LiquidationLogic.executeLiquidationCall()`
- Computes borrower HF through `GenericLogic.calculateUserAccountData()`.
- `_calculateDebt()` applies close factor:
  - 50% default close factor
  - 100% close factor when HF `< 0.95e18`
- `validateLiquidationCall()` ensures active/unpaused reserves, valid collateral flag, nonzero debt, and sentinel allowance.
- `_getConfigurationData()` selects collateral/debt price sources and liquidation bonus, including eMode overrides.
- `_calculateAvailableCollateralToLiquidate()` computes collateral seized and protocol liquidation fee.
- Burns debt, updates debt reserve rates, updates isolation accounting, then either:
  - transfers collateral aTokens to liquidator
  - or burns collateral aTokens and sends underlying
- Finally pulls debt asset from liquidator into the debt reserve aToken.
- Review focus:
  - liquidation is a cross-reserve state transition gated by account-level solvency
  - debt-side settlement and collateral-side settlement happen across two reserves with separate index updates
  - protocol liquidation fee is taken from the collateral side and paid in aTokens to treasury
  - user collateral flag is disabled when seized collateral plus protocol fee exhausts balance

### `_calculateDebt()`
- Reads user stable and variable debt.
- Caps liquidatable debt by close factor unless caller requests less.
- Review focus:
  - stable/variable mix matters for later burn ordering

### `_calculateAvailableCollateralToLiquidate()`
- Prices debt and collateral through oracle sources, applies liquidation bonus, bounds seizure by user collateral balance, and derives protocol fee.
- Review focus:
  - oracle price source choice is a primary trust boundary
  - rounding determines whether liquidator or protocol captures residual wei

---

## Flash Loan / Bridge Layer

### `FlashLoanLogic.executeFlashLoan()`
- Validates reserve availability first, transfers underlying out, executes receiver callback, then either pulls repayment plus premium or opens debt.
- Authorized flash borrowers pay zero premium.
- Review focus:
  - multi-asset loop means partial asset choices can mix repayment and debt-open branches in one call
  - callback happens before reserve cache/state refresh on purpose

### `FlashLoanLogic.executeFlashLoanSimple()`
- Single-asset version with mandatory repayment and no fee waiver.
- Review focus:
  - simpler surface, but same repayment-accounting risks

### `FlashLoanLogic._handleFlashLoanRepayment()`
- Splits total premium between protocol and LPs.
- LP share is capitalized into liquidity index via `cumulateToLiquidityIndex()`.
- Protocol share is added to `accruedToTreasury` in scaled units.
- Review focus:
  - treasury accrual and LP accrual use different units and rounding paths
  - repayment is pulled after index/rate update, relying on transaction rollback if transfer fails

### `BridgeLogic.executeMintUnbacked()`
- Reuses supply validation but skips underlying transfer.
- Increments `reserve.unbacked` and checks unbacked mint cap.
- Review focus:
  - creates tokenized supplier claim before backing arrives

### `BridgeLogic.executeBackUnbacked()`
- Caps backing by current `reserve.unbacked`.
- Fee is split LP/protocol similarly to flashloan premium handling.
- Review focus:
  - backer can send more than current unbacked request amount, but only existing unbacked gets cleared

---

## Solvency / Validation Layer

### `GenericLogic.calculateUserAccountData()`
- The main solvency engine.
- Iterates only reserves where `userConfig` says the user is supplying or borrowing.
- For collateral:
  - values aToken scaled balance at normalized income
  - applies either reserve LTV / liquidation threshold or eMode overrides
- For debt:
  - values variable debt as scaled variable balance times normalized debt
  - adds stable debt token balance
- Outputs:
  - total collateral in base currency
  - total debt in base currency
  - weighted average LTV
  - weighted average liquidation threshold
  - health factor
  - `hasZeroLtvCollateral`
- Review focus:
  - reserve-list iteration and `userConfig` bits must stay synchronized
  - eMode can replace both price source and risk params for in-category assets
  - zero-LTV collateral is tracked separately because it affects withdrawal / transfer legality even when HF is healthy
  - this function is the shared solvency dependency for borrow, withdraw, liquidation, and multiple validation gates; valuation drift here propagates protocol-wide

### `GenericLogic.calculateAvailableBorrows()`
- Returns `collateral * ltv - debt`, floored at zero.
- Review focus:
  - this is the user-facing borrow headroom number, but actual borrow validation also checks caps, modes, and sentinels

### `ValidationLogic.validateSupply()`
- Requires nonzero amount, active reserve, not paused, not frozen, and supply cap not exceeded.
- Supply cap includes existing scaled aToken supply plus treasury accrual, all normalized by next liquidity index.

### `ValidationLogic.validateBorrow()`
- Requires active reserve, not paused/frozen, borrowing enabled, valid interest-rate mode, oracle sentinel approval, and adequate collateral/HF.
- Enforces:
  - borrow cap
  - isolation borrowability and debt ceiling
  - eMode asset-category consistency
  - stable borrow restrictions
  - siloed borrowing restrictions
- Review focus:
  - this is the densest policy gate in the protocol
  - stable/self-collateral, eMode, isolation, and siloed logic all intersect here

### `ValidationLogic.validateRepay()`
- Requires nonzero amount, active reserve, not paused, and debt existing in selected rate mode.
- `uint256.max` on-behalf repay is only allowed for self-repay.

### `ValidationLogic.validateLiquidationCall()`
- Requires both reserves active and not paused.
- Requires HF below `1e18`.
- If sentinel exists and HF is not already below `0.95e18`, liquidation also requires sentinel approval.
- Requires collateral flag to be enabled and debt on selected asset to be nonzero.

### `ValidationLogic.validateHFAndLtv()`
- Recomputes HF after collateral-reducing action.
- Adds extra guard for zero-LTV collateral composition.
- Review focus:
  - healthy HF alone is not enough when zero-LTV collateral remains in the basket

### `ValidationLogic.validateSetUserEMode()`
- Category must exist.
- If user already borrows, every borrowed reserve must belong to target category before nonzero eMode can be enabled.

### `ValidationLogic.validateUseAsCollateral()` / `validateAutomaticUseAsCollateral()`
- Asset must have nonzero LTV.
- If user already has collateral enabled, isolated-collateral rules restrict adding more.
- Automatic enablement for isolated collateral additionally requires `ISOLATED_COLLATERAL_SUPPLIER_ROLE`.
- Review focus:
  - explicit enablement and automatic enablement are intentionally not identical

---

## Reserve Accounting Layer

### `ReserveLogic.getNormalizedIncome()`
- Returns current liquidity index if updated this block, else linearly accrues liquidity rate.
- Review focus:
  - supply-side claims use linear accrual

### `ReserveLogic.getNormalizedDebt()`
- Returns current variable borrow index if updated this block, else compound-accrues variable borrow rate.
- Review focus:
  - debt-side growth uses compounded accrual, not linear

### `ReserveLogic.updateState()`
- If timestamp changed:
  - `_updateIndexes()`
  - `_accrueToTreasury()`
  - write new timestamp
- Review focus:
  - nearly every state-changing path relies on this lazy accrual boundary

### `ReserveLogic.updateInterestRates()`
- Calls external interest-rate strategy with current reserve state and action deltas.
- Writes next liquidity / stable borrow / variable borrow rates.
- Review focus:
  - rate strategy is a major external trust boundary
  - wrong `liquidityAdded` / `liquidityTaken` inputs would distort all future accrual

### `ReserveLogic._accrueToTreasury()`
- Computes debt accrued since last update and mints reserve-factor share to treasury in scaled units.
- Uses:
  - previous variable debt from old index
  - current variable debt from next index
  - stable debt accrued from average stable rate
- Review focus:
  - treasury accrual is computed from debt-growth accounting rather than direct token balances
  - rounding here affects protocol revenue but also total supplier claim dilution

### `ReserveLogic._updateIndexes()`
- Updates liquidity index only when liquidity rate is nonzero.
- Updates variable borrow index only when scaled variable debt is nonzero.
- Review focus:
  - variable borrow index only updates when scaled variable debt is nonzero

### `ReserveLogic.cumulateToLiquidityIndex()`
- Instantaneously distributes fixed income into liquidity index.
- Used for flashloan premiums and bridge backing fees.
- Review focus:
  - direct fee capitalization is separate from time-based interest accrual

### `ReserveLogic.cache()`
- Snapshot of reserve configuration, indexes, rates, debt totals, token addresses, and timestamps.
- Review focus:
  - many functions assume this cache stays coherent with later mutations to `next*` fields

---

## eMode / Isolation Layer

### `EModeLogic.executeSetUserEMode()`
- Validates category compatibility, updates user eMode category, then re-checks HF if exiting a prior nonzero category.
- Review focus:
  - category switch can change both valuation and thresholds without changing balances

### `EModeLogic.getEModeConfiguration()`
- Returns category LTV, liquidation threshold, and optional custom price source price.

### `IsolationModeLogic.updateIsolatedDebtIfIsolated()`
- Decrements isolated debt in debt-ceiling units on repay or liquidation.
- If repay amount exceeds recorded isolated principal due to accrued interest, total isolated debt is floored to zero.
- Review focus:
  - ceiling accounting is principal-like and deliberately decoupled from live interest-bearing debt

---

## Configuration / Governance Layer

### `PoolConfigurator.configureReserveAsCollateral()`
- Requires `ltv <= liquidationThreshold`.
- If collateral enabled:
  - liquidation bonus must be `> 100%`
  - threshold * bonus must still be economically coverable
- If disabling collateral by setting threshold to zero:
  - liquidation bonus must be zero
  - reserve must have no suppliers
- Review focus:
  - config changes directly redefine user solvency math

### `PoolConfigurator.setReserveBorrowing()` / `setReserveStableRateBorrowing()`
- Borrowing cannot be disabled while stable borrowing remains enabled.
- Stable borrowing cannot be enabled unless borrowing is enabled.

### `PoolConfigurator.setDebtCeiling()`
- If moving from non-isolated to isolated collateral mode, reserve must have no suppliers.
- If ceiling is reset to zero, pool isolation total debt is reset.
- Review focus:
  - config mutation can invalidate assumptions of existing collateral compositions

### `PoolConfigurator.setSiloedBorrowing()`
- Enabling siloed borrowing requires no existing borrowers.
- Review focus:
  - prevents retroactively trapping multi-asset debt positions into incompatible mode

### `PoolConfigurator.setBorrowCap()` / `setSupplyCap()` / `setLiquidationProtocolFee()`
- Core per-reserve risk knobs affecting entry size, reserve growth, and liquidation value split.

### `PoolConfigurator.setEModeCategory()` / `setAssetEModeCategory()`
- Category params must be internally coherent and strictly more permissive than assigned assets’ base collateral params.
- Asset cannot be assigned to an eMode category with weaker liquidation threshold than its current reserve threshold.
- Review focus:
  - eMode is a separate solvency regime, not only a UI label

### `PoolConfigurator.setUnbackedMintCap()`
- Caps bridge-created unbacked exposure.

### `PoolConfigurator.setReserveInterestRateStrategyAddress()`
- Repoints reserve to a new external rate strategy.
- Review focus:
  - one of the most sensitive governance trust boundaries

### `PoolConfigurator.updateBridgeProtocolFee()` / `updateFlashloanPremiumTotal()` / `updateFlashloanPremiumToProtocol()`
- Adjusts protocol take rates for bridge backing and flashloan paths.
- Review focus:
  - these values affect treasury accrual and LP economics, not reserve solvency directly unless misconfigured to extreme values