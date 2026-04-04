# Function Notes

## Architecture / Storage Layer

### `constructor(address newOwner)`
- Sets the immutable EIP-712 `DOMAIN_SEPARATOR` using `block.chainid` and `address(this)`.
- Initializes `owner`.
- Review implication: signature validity is scoped to this contract and chain context, but cached domain-separator designs should still be reviewed for fork/replay assumptions.

### `marketParams.id()`
- Morpho derives a canonical `Id` from the `MarketParams` tuple and uses that as the key for:
  - `market[id]`
  - `position[id][user]`
  - `idToMarketParams[id]`
- Review implication: every market-level state transition assumes the provided `marketParams` matches the market keyed by `id`.

### `position[id][user]`
- Stores:
  - `supplyShares`
  - `borrowShares`
  - `collateral`
- Note that supply and borrow are tracked in shares, while collateral is tracked directly in token amount.

### `market[id]`
- Stores:
  - `totalSupplyAssets`
  - `totalSupplyShares`
  - `totalBorrowAssets`
  - `totalBorrowShares`
  - `lastUpdate`
  - `fee`
- Review implication: lazy accrual means these values may lag “real time” until `_accrueInterest()` is called.

## Owner / Configuration Layer

### `setOwner(address newOwner)`
- Owner-only.
- Directly replaces `owner`.
- Review implication: there is no two-step ownership transfer.

### `enableIrm(address irm)`
- Owner-only.
- Permanently enables an IRM address for market creation.
- IRMs cannot be disabled later.
- Review implication: IRM allowlisting is a major trust boundary because any enabled IRM can be reused in future markets.

### `enableLltv(uint256 lltv)`
- Owner-only.
- Permanently enables an LLTV value for market creation.
- Requires `lltv < WAD`.
- Review implication: LLTV allowlisting is also irreversible and defines how much liquidation slack future markets can use.

### `setFee(MarketParams memory marketParams, uint256 newFee)`
- Owner-only.
- Requires existing market.
- Accrues interest using the old fee before updating to the new fee.
- Requires `newFee <= MAX_FEE`.
- Review implication: fee changes are not purely forward-looking unless interest is accrued first, which Morpho explicitly does here.

### `setFeeRecipient(address newFeeRecipient)`
- Owner-only.
- Updates the address that receives fee-accrued supply shares.
- Review implication: fee recipient is not market-specific; all market fee accrual routes here.

## Market Creation Layer

### `createMarket(MarketParams memory marketParams)`
- Permissionless once `irm` and `lltv` have been enabled by the owner.
- Initializes `market[id].lastUpdate` and stores `idToMarketParams[id]`.
- Calls `IIrm(marketParams.irm).borrowRate(...)` once to initialize a stateful IRM if needed.
- Review implication:
  - market creation is permissionless but dependency allowlisting is centralized
  - market creation inherits all correctness and liveness assumptions of the chosen IRM, oracle, and tokens
  - fresh markets should be treated as a separate risk regime because low-liquidity and initial share-state behavior can differ materially from mature markets

## Conversion / Share Math Layer

### `SharesMathLib.toSharesDown / toSharesUp / toAssetsDown / toAssetsUp`
- Convert between assets and shares using:
  - `totalAssets`
  - `totalShares`
  - `VIRTUAL_SHARES`
  - `VIRTUAL_ASSETS`
- Review implication:
  - Morpho relies heavily on directional rounding for safety
  - virtual shares / assets reduce empty-market manipulation risk but should still be reviewed for precision edge cases
  - virtual shares and virtual assets regularize empty-market behavior, but they also create a distinct tiny-market regime where phantom balances can influence repricing, residual debt, and supplier claim growth

### Supply-side conversions
- `supply`
  - assets input -> `toSharesDown`
  - shares input -> `toAssetsUp`
- `withdraw`
  - assets input -> `toSharesUp`
  - shares input -> `toAssetsDown`
- Review implication: supply/withdraw rounding systematically favors protocol safety against over-minting or over-withdrawing.

### Borrow-side conversions
- `borrow`
  - assets input -> `toSharesUp`
  - shares input -> `toAssetsDown`
- `repay`
  - assets input -> `toSharesDown`
  - shares input -> `toAssetsUp`
- Review implication: borrow/repay rounding also intentionally favors protocol safety.

## Supply / Withdraw Layer

### `supply(...)`
- Requires exactly one of `assets` or `shares` to be zero.
- Accrues interest first.
- Converts between assets and shares depending on caller intent.
- Increases:
  - `position[id][onBehalf].supplyShares`
  - `market[id].totalSupplyShares`
  - `market[id].totalSupplyAssets`
- Optionally calls back into `msg.sender` through `onMorphoSupply`.
- Pulls `loanToken` from the caller at the end.
- Review focus:
  - state is updated before the final token pull
  - callback is invoked before the final token pull
  - safety relies on atomic rollback if callback or transfer fails

### `withdraw(...)`
- Requires authorization on `onBehalf`.
- Accrues interest first.
- Converts assets/shares with conservative rounding.
- Decreases supply position and market totals.
- Requires post-withdraw `totalBorrowAssets <= totalSupplyAssets`.
- Transfers `loanToken` to `receiver`.
- Review focus:
  - liquidity check is market-level, not user-level
  - path dependence can arise because lazy accrual and current liquidity state affect conversions and success

## Borrow / Repay Layer

### `borrow(...)`
- Requires authorization on `onBehalf`.
- Accrues interest first.
- Converts between assets and borrow shares.
- Increases:
  - `position[id][onBehalf].borrowShares`
  - `market[id].totalBorrowShares`
  - `market[id].totalBorrowAssets`
- Requires:
  - position remains healthy
  - market liquidity remains sufficient
- Transfers `loanToken` to `receiver`.
- Review focus:
  - health check happens after debt growth
  - liquidity and health both depend on freshly accrued state

### `repay(...)`
- Accrues interest first.
- Converts between assets and borrow shares.
- Decreases borrower debt shares and market debt totals.
- Uses `zeroFloorSub` for `totalBorrowAssets`, so `assets` may exceed remaining total borrow assets by 1 due to rounding.
- Optionally calls back into `msg.sender` through `onMorphoRepay`.
- Pulls `loanToken` from the caller at the end.
- Review focus:
  - callback and token pull ordering mirrors `supply`
  - repay amount can be slightly greater than residual debt due to rounding
  - in tiny markets, repaying all borrower-owned shares may still leave recorded borrow assets because market-level conversion math includes virtual balances

## Collateral Layer

### `supplyCollateral(...)`
- Requires nonzero assets and nonzero `onBehalf`.
- Does **not** accrue interest.
- Increases `position[id][onBehalf].collateral`.
- Optionally calls back into `msg.sender` through `onMorphoSupplyCollateral`.
- Pulls `collateralToken` from the caller at the end.
- Review focus:
  - this is intentionally asymmetric with most other state-changing functions because it skips accrual
  - review whether collateral top-ups immediately before other actions create any surprising sequencing behavior

### `withdrawCollateral(...)`
- Requires authorization on `onBehalf`.
- Accrues interest first.
- Decreases collateral balance.
- Re-checks health after withdrawal.
- Transfers `collateralToken` to `receiver`.
- Review focus:
  - health check uses freshly accrued debt and fresh oracle price
  - contrast with `supplyCollateral`, which skips accrual

## Liquidation Layer

### `liquidate(...)`
- Permissionless.
- Requires exactly one of:
  - `seizedAssets`
  - `repaidShares`
  to be zero.
- Accrues interest first.
- Fetches oracle price and requires borrower to be unhealthy.

**Branch 1: caller specifies `seizedAssets`**
- Quotes seized collateral into loan-asset value.
- Divides by liquidation incentive factor.
- Converts resulting debt value into `repaidShares`.

**Branch 2: caller specifies `repaidShares`**
- Converts debt shares into debt assets.
- Applies liquidation incentive factor.
- Converts resulting quoted value into collateral amount `seizedAssets`.

**Settlement**
- Computes `repaidAssets` from `repaidShares`.
- Reduces borrower borrow shares and collateral.
- Reduces market borrow totals.
- If collateral reaches zero:
  - remaining borrow shares become bad debt
  - bad debt is removed from both borrow assets and supply assets
  - borrower borrow shares are zeroed
- Transfers seized collateral to the liquidator.
- Optionally calls `onMorphoLiquidate`.
- Pulls repaid `loanToken` from the liquidator at the end.

**Review focus**
- liquidation depends critically on oracle price, rounding direction, and incentive math
- bad-debt cleanup directly reduces `totalSupplyAssets`, so supplier-side value can be impaired by exhausted collateral
- bad debt is realized only when collateral reaches zero, which makes partial-liquidation sequencing economically important
- caller-controlled choice between seized-collateral input and repaid-shares input is a meaningful edge-case surface

## Flash Loan Layer

### `flashLoan(address token, uint256 assets, bytes calldata data)`
- Permissionless.
- Transfers `token` to `msg.sender`.
- Calls `onMorphoFlashLoan(assets, data)` on `msg.sender`.
- Pulls the same token amount back with `transferFrom`.
- Review focus:
  - no collateral is required because repayment is enforced atomically
  - borrower gets arbitrary one-transaction control flow during callback
  - main safety assumptions reduce to atomic repayment, callback rollback, and token correctness

## Authorization / Signature Layer

### `setAuthorization(address authorized, bool newIsAuthorized)`
- Directly toggles whether `authorized` may manage the caller’s positions.
- Reverts if the value is already set.

### `setAuthorizationWithSig(Authorization memory authorization, Signature calldata signature)`
- EIP-712 signature-based authorization flow.
- Checks:
  - deadline not expired
  - supplied nonce matches `nonce[authorizer]`
- Increments nonce as part of validation.
- Hashes the `Authorization` struct using EIP-712.
- Recovers signer with `ecrecover`.
- Requires signer to equal `authorization.authorizer`.
- Writes:
  - `isAuthorized[authorizer][authorized] = authorization.isAuthorized`
- Review focus:
  - replay resistance depends on nonce and deadline handling
  - function intentionally does not reject “already set” states because nonce consumption is part of the desired semantics

### `_isSenderAuthorized(address onBehalf)`
- Returns true when:
  - `msg.sender == onBehalf`
  - or `isAuthorized[onBehalf][msg.sender]`
- This is the central authority check for delegated position management.

## Interest / Fee Accrual Layer

### `accrueInterest(MarketParams memory marketParams)`
- Public entrypoint that forces interest accrual for a market.

### `_accrueInterest(MarketParams memory marketParams, Id id)`
- Returns early if `elapsed == 0`.
- If `marketParams.irm != address(0)`:
  - calls external `IIrm.borrowRate(...)`
  - computes compounded interest over elapsed time
  - adds interest to both `totalBorrowAssets` and `totalSupplyAssets`
- If market fee is nonzero:
  - computes fee amount from interest
  - converts fee amount into supply shares
  - credits those shares to `feeRecipient`
  - increases `totalSupplyShares`
- Updates `lastUpdate`.

**Review focus**
- this is the main accounting crystallization path in Morpho
- IRM correctness and rate sanity are critical to both solvency and liveness
- fee minting dilutes suppliers through share issuance, not direct asset transfer
- because accrual is lazy, any action that triggers it can observe a materially different accounting state from an action that does not

## Health Check Layer

### `_isHealthy(marketParams, id, borrower)`
- Returns true immediately if `borrowShares == 0`.
- Otherwise fetches oracle price and delegates to the priced overload.

### `_isHealthy(marketParams, id, borrower, collateralPrice)`
- Converts borrower `borrowShares` into debt assets using `toAssetsUp`.
- Computes max borrow from:
  - collateral amount
  - oracle price
  - `lltv`
- Returns whether `maxBorrow >= borrowed`.
- Review focus:
  - rounds in favor of protocol safety
  - health depends directly on oracle scaling and borrow-share conversion
  - this is an oracle-valued accounting health test, not a guarantee that liquidation proceeds are sufficient under all stressed market conditions

## Storage View Layer

### `extSloads(bytes32[] calldata slots)`
- Returns raw storage values for arbitrary slots.
- Purely read-only introspection helper.
- Review implication: not a write-risk, but useful for precise external state inspection and off-chain accounting analysis.
