# Function Notes

## Architecture / Storage Layer

### `MarketFactory.create(...)`
- Owner-only market creation.
- Deploys a new `Market` instance and initializes it with:
  - settlement token
  - oracle
- Review implication:
  - market creation is not permissionless
  - unsafe market definitions are still a critical governance/configuration risk

### `Market.initialize(...)`
- Initializes inherited instance / reentrancy state and stores market definition.
- Sets the verifier / oracle / token references for the market.
- Review implication:
  - initialization correctness matters because `Market` is an instance-style deployed contract, not a constructor-only singleton

### `Global`
- Live market-wide state:
  - latest/current global order ids
  - fee buckets
  - `pAccumulator`
  - `exposure`
- Review implication:
  - `Global` is not just metadata; it contains accounting state that must remain coherent across parameter updates and settlement

### `Local`
- Live account-wide state for one market/account pair:
  - latest/current local order ids
  - collateral
  - claimable balances
  - protection / invalidation-related flags
- Review implication:
  - `Local` is the current account anchor, distinct from historical `Checkpoint`

### `Version`
- Historical market-wide cumulative accumulator snapshot keyed by oracle timestamp/version.
- Contains:
  - `valid`
  - `price`
  - cumulative fee / offset / maker-long-short value accumulators
- Review implication:
  - `Version` is the global accounting anchor consumed by `CheckpointLib`

### `Checkpoint`
- Historical account-level settlement snapshot keyed by version/timestamp.
- Encodes the local result of applying global version deltas to one account.
- Review implication:
  - a local accounting error here directly changes user collateral

### `Context`
- In-memory bundle used by `Market.sol` that contains:
  - market-wide state
  - one chosen account's local state
  - current/latest oracle versions
- It is account-specific even though it also includes global state.

## Owner / Configuration Layer

### `MarketFactory.updateParameter(...)`
- Factory owner updates `ProtocolParameter`.
- Protocol-wide bounds later constrain market-level risk parameters.
- Review implication:
  - protocol parameter changes indirectly change what market risk configurations are valid

### `Market.updateParameter(MarketParameter memory newParameter)`
- Owner-only.
- Updates market-level operational parameters such as:
  - funding fee
  - interest fee
  - maker/taker base trade fee
  - pending limits
  - `closed`
  - `settle`
- Review implication:
  - this is an economic and liveness surface, not just a metadata surface

### `Market.updateRiskParameter(RiskParameter memory newRiskParameter)`
- Coordinator-only.
- Validates risk parameter against factory-level `ProtocolParameter`.
- Reconciles `Global` against the parameter change via `Global.update(...)`.
- Review implication:
  - risk-parameter changes are not purely forward-looking
  - old global controller / exposure state must be made coherent under the new configuration

### `Market.updateCoordinator(address newCoordinator)`
- Owner-only.
- Changes the market's risk-parameter manager.
- Review implication:
  - coordinator is a privileged economic actor even if not directly a fund-moving one

## Settlement Layer

### `settle(address account)`
- Public account-specific settlement entrypoint.
- Loads market + local context for `account`, settles it, stores updated context.
- Review implication:
  - settlement is account-scoped, but can also advance global state required for that account

### `_settle(Context memory context)`
- Internal settlement engine.
- Mutates the in-memory `context` in place.
- Processes:
  - pending global orders from `global.currentId + 1` forward while ready
  - pending local orders from `local.currentId + 1` forward while ready
- Review implication:
  - correctness depends heavily on queue ordering, readiness gating, and storing the mutated context later

### `_processOrderGlobal(...)`
- Consumes one pending global order and rolls market-wide accounting forward.
- Main effects:
  - update global position
  - compute / store new `Version`
  - advance global order cursor
- Review implication:
  - this is the handoff point from pending order flow into `VersionLib`

### `_processOrderLocal(...)`
- Consumes one pending local order for one account.
- Main effects:
  - compute local `Checkpoint`
  - update local position / collateral / claimable values
  - advance local order cursor
- Review implication:
  - local sequencing must exactly match the global version interval the order belongs to

### `pendingOrder(uint256 id)`
- Returns the global pending `Order` at a given id.
- If unread/unwritten in storage, mapping semantics imply default-zero struct behavior.
- Review implication:
  - callers must distinguish real queued orders from zero/default reads via surrounding id logic

### `versions(uint256 timestamp)`
- Returns the `Version` stored at a timestamp key.
- Missing keys yield the default-zero `Version`.
- Review implication:
  - `valid` and surrounding sequencing logic matter; mapping reads do not revert on absent versions

## Update Surface

### `update(address account, Fixed6 amount, address referrer)`
- Direct taker delta update.
- Calls `_updateMarket(account, msg.sender, 0, amount, 0, referrer)`.
- Semantics:
  - `amount > 0` increases long taker exposure
  - `amount < 0` increases short taker exposure
- Review implication:
  - this is the simplest direct taker entrypoint, without signed-message flow

### `update(address account, Fixed6 makerAmount, Fixed6 takerAmount, Fixed6 collateral, address referrer)`
- Direct delta-based market update.
- Can adjust:
  - maker
  - taker skew
  - collateral
- Review implication:
  - core direct entrypoint for manual maker/taker/collateral movement

### `update(address account, UFixed6 newMaker, UFixed6 newLong, UFixed6 newShort, Fixed6 collateral, bool protect, address referrer)`
- Absolute-position update entrypoint.
- Computes deltas from current local position to target maker/long/short.
- `protect` controls protected-order behavior on the new order.
- Review implication:
  - absolute-target APIs are often where sign / direction / target-vs-delta mistakes surface

### `update(Take calldata take, bytes memory signature)`
- Signed direct taker update.
- Verifies a `Take` message, then routes to `_updateMarket(...)`.
- No guarantee / intent price semantics are involved.
- Review implication:
  - compare auth and sequencing against direct update path

### `update(address account, Intent calldata intent, bytes memory signature)`
- Direct intent fill path with one signed side.
- Verifies only the trader-side `Intent`.
- Calls `_updateIntent(...)` twice:
  - once for the explicit counterparty/filler account
  - once for the trader/intender account
- Review implication:
  - this path pairs two explicit account legs rather than routing against anonymous pooled liquidity

### `update(Fill calldata fill, bytes memory traderSignature, bytes memory solverSignature)`
- Matched/signed fill path with both trader and solver signatures.
- Verifies:
  - `Intent`
  - `Fill`
- Calls `_updateIntent(...)` twice:
  - once for solver/counterparty leg
  - once for trader leg
- Review implication:
  - this path should be reviewed separately from direct intent fill because both sides are explicitly signed and domain-bound

## Internal Update / Order Construction Layer

### `_loadForUpdate(...)`
- Loads context and update-side derived data for one account/signing path.
- Settles first before constructing the new order.
- Review implication:
  - most update flows rely on implicit settlement here rather than on callers invoking `settle()` themselves

### `_loadUpdateContext(...)`
- `view` helper that derives current positions and referral settings in memory.
- Updates memory-only `Position` copies such as `currentPositionGlobal` / `currentPositionLocal`.
- Review implication:
  - `view` is not contradicted by mutating memory structs; only storage writes are forbidden

### `_updateMarket(...)`
- Generic direct-update path used by unsigned updates and signed `Take`.
- Creates a new `Order` from maker/taker/collateral deltas.
- Creates a fresh/no-op `Guarantee`.
- Then calls `_updateAndStore(...)`.
- Review implication:
  - this is the normal pooled-market update path, without guaranteed-price sidecar semantics

### `_updateIntent(...)`
- Intent-specific internal update path.
- Loads and settles context, then creates:
  - `Order` from signed amount and current position
  - `Guarantee` from order + intent execution parameters
- Then calls `_updateAndStore(...)`.
- Review implication:
  - this is where guaranteed execution semantics enter accounting

### `_updateAndStore(...)`
- Common handoff after creating `newOrder` and `newGuarantee`.
- Adds order/guarantee to:
  - local/global pending queues
  - aggregated pending order/guarantee state
- Stores referrer mappings where relevant.
- Review implication:
  - any inconsistency here can desynchronize queue contents from aggregated pending state

### `OrderLib.from(...)`
- Converts signed maker/taker/collateral deltas into unsigned directional buckets:
  - `makerPos` / `makerNeg`
  - `longPos` / `longNeg`
  - `shortPos` / `shortNeg`
- A non-empty order gets `orders = 1`.
- Review implication:
  - `orders` is not notional size; it is discrete order/action count used by settlement-fee logic

### `GuaranteeLib.from(...)`
- Creates guarantee-side accounting metadata from an order plus intent execution parameters.
- Includes:
  - guaranteed taker quantities
  - guaranteed fee exclusion quantities
  - price adjustment
  - solver/originator referral information
- Conceptually:
  - `notional = signed taker size × guaranteed price`
  - this later feeds `priceAdjustment(...)` so guaranteed execution can be reconciled against oracle settlement price
- Review implication:
  - `Guarantee` is a sidecar accounting object, not just a boolean fee exemption

## Global Accounting Layer: `VersionLib`

### `_accumulate(...)`
- Main market-wide roll-forward for one oracle step.
- Carries previous accumulators forward, then adds all new components.

### `_accumulateSettlementFee(...)`
- Computes per-order settlement fee index movement.
- Conceptually:
  - `orders = order.orders - guarantee.orders`
  - `settlementFeeIndexDelta = - settlementFee / orders`
- Review implication:
  - order count and guarantee exclusions must be exact

### `_accumulateLiquidationFee(...)`
- Computes the per-protected-unit liquidation fee index.
- Uses oracle settlement fee and `riskParameter.liquidationFee`.
- Review implication:
  - review whether protected quantity is charged once and only once

### `_accumulateFee(...)`
- Computes base maker/taker trade fees.
- Main formulas:
  - `makerFee = makerTotal * |price| * makerFeeRate`
  - `takerFee = takerTotal * |price| * takerFeeRate`
- Writes negative fee accumulators and splits:
  - `tradeFee`
  - `subtractiveFee`
- `subtractiveFee` is the referral-directed portion of gross maker/taker trade fee.
- `solverFee` is a subset carved out of taker-side referral share.
- Review implication:
  - this is separate from offset accounting and should not be conflated with price impact

### `_accumulateLinearFee(...)`
- Computes linear execution-offset fees for:
  - maker flow
  - taker positive flow
  - taker negative flow
- Writes negative offset accumulators.
- Routes collected offset value to:
  - makers if maker liquidity exists
  - otherwise market-level bucket
- Review implication:
  - review both payer-side negative offsets and receiver-side positive maker value as one transfer

### `_accumulateProportionalFee(...)`
- Same accounting shape as `_accumulateLinearFee(...)`, but uses:
  - `|change| * |price| * (|change| / scale) * proportionalFeeRate`
- Review implication:
  - denominator and scale handling are critical

### `_accumulateAdiabaticFee(...)`
- Computes skew-sensitive execution cost for taker positive / negative flow.
- Formula shape:
  - `adiabaticFee = change * price * adiabaticRate * average(normalized skew across path)`
- Writes:
  - negative taker offset accumulators
  - positive `result.tradeOffset`
- Review implication:
  - this is a transaction-time skew fee, not price-move PnL

### `_accumulateAdiabaticExposure(...)`
- Computes PnL from previously accumulated skew exposure across a price move.
- Key formulas:
  - `exposure = (adiabaticRate * skew^2) / (2 * scale)`
  - `adiabaticExposure = (p1 - p0) * exposure`
- Routes result to:
  - maker value if makers exist
  - otherwise market-level exposure bucket
- Review implication:
  - this is not a new trade fee; it is a price-move realization of old skew state

### `_accumulateFunding(...)`
- Computes time-based long-short funding using:
  - `pAccumulator`
  - `pController`
  - normalized skew
  - taker-socialized notional
- Core steps:
  - compute controller-integrated funding amount
  - initialize long/short as equal and opposite
  - take protocol fee spread
  - redirect part of minor-side funding to maker
- Review implication:
  - funding is stateful and path-dependent; it is not a simple `skew * time * price` formula

### `_accumulateInterest(...)`
- Computes utilization-based maker interest on:
  - `notional = min(long + short, maker) * |price|`
- Utilization:
  - `u = min(max(netUtilization, efficiencyUtilization), 1)`
- Interest:
  - `rate(u) * dt / 365d * notional`
- Takers pay proportionally; makers receive net of protocol interest fee.
- Review implication:
  - review zero-maker, zero-taker, and highly imbalanced markets carefully

### `_accumulatePNL(...)`
- Computes pure directional price PnL.
- Uses socialized taker sizes:
  - `longSocialized = min(maker + short, long)`
  - `shortSocialized = min(maker + long, short)`
- Main formulas:
  - `pnlLong = (p1 - p0) * longSocialized`
  - `pnlShort = (p0 - p1) * shortSocialized`
  - `pnlMaker = - (pnlLong + pnlShort)`
- Review implication:
  - this is the cleanest price-only value transfer and is a useful accounting sanity anchor

## Local Accounting Layer: `CheckpointLib`

### `accumulate(...)`
- Account-local realization entrypoint for one order/version interval.
- Applies `fromVersion -> toVersion` accumulator changes to the account's prior position/order.
- Review implication:
  - any mismatch here creates direct user-side over/under-settlement

### `_accumulateCollateral(...)`
- Applies `makerValue`, `longValue`, and `shortValue` deltas to the account's prior position.
- This is where:
  - funding
  - interest
  - price PnL
  - adiabatic exposure value
  are realized into local collateral delta

### `_accumulatePriceOverride(...)`
- Realizes the net guaranteed-execution correction.
- Conceptually:
  - `priceOverride = signed taker size × (oracle settlement price - guaranteed price)`
- Positive when the guarantee is favorable to the trader.
- Negative when the guarantee is unfavorable to the trader.
- Review implication:
  - guaranteed execution value transfer belongs here, not in base PnL

### `_accumulateFee(...)`
- Realizes maker/taker trade fees from global fee accumulators.
- Accumulators are stored as negative deltas, so local logic converts them into positive fee magnitudes.
- Review implication:
  - sign handling and denominator choice are easy places for overcharge bugs

### `_accumulateOffset(...)`
- Realizes the account/order share of:
  - `makerOffset`
  - `takerPosOffset`
  - `takerNegOffset`
- These offsets come from:
  - linear execution-cost accumulators
  - proportional execution-cost accumulators
  - adiabatic execution-cost accumulators
- They are distinct from ordinary maker/taker trade fees.
- Review implication:
  - offsets and trade fees are distinct domains and should not be accidentally merged

### `_accumulateSettlementFee(...)`
- Realizes per-order settlement fee for the account's fee-bearing order count.
- This is not notional-based.
- Guaranteed orders reduce the fee-bearing count through:
  - `order.orders - guarantee.orders`

### `_accumulateLiquidationFee(...)`
- Realizes the protected-order liquidation/protection fee.
- Uses the version's liquidation-fee accumulator with:
  - base zero
  - quantity one
- This is a discrete per-protected-order charge, not a running position-value delta.
- Its presence does not by itself prove the account was liquidated in the intuitive UI sense.

### `_response(...)`
- Produces the final local settlement response used to update collateral / claimable balances.
- Conceptually:
  - `collateralDelta = valueDelta + priceOverride - tradeFee - offset - settlementFee - liquidationFee`
- `response.collateral` is not raw deposited collateral.
- It is the net realized account-value delta posted at checkpoint settlement.

## Claim / Residual Settlement Layer

### `claimFee(address account)`
- Operator-authorized.
- Claims previously accumulated `Local.claimable`-type balances.
- This is not the normal path for realizing maker/taker funding/interest/PnL.
- Review implication:
  - do not conflate claimable fee balances with ordinary collateral settlement

### `claimExposure()`
- Owner-only.
- Settles market-level `Global.exposure` by:
  - pushing tokens out if market owes owner
  - pulling tokens in if owner owes market
- Then zeroes the exposure bucket.
- Review implication:
  - this is the final settlement path for residual market-level exposure and deserves separate sign/fairness review

## Verifier / Signed Message Layer

### `Verifier.verifyIntent(...)`
- Validates signed trader intent:
  - signer authorization
  - domain
  - nonce/group/expiry
  - EIP-712 signature

### `Verifier.verifyFill(...)`
- Validates signed fill / solver-side message.

### `Verifier.verifyTake(...)`
- Validates signed direct taker update.

### Common review implication
- These functions are authorization boundaries, not just helper checks.
- Cross-market replay, wrong-domain execution, stale nonce reuse, and signer/operator mismatch all belong here.

## Initial Function-Level Review Priorities
- Trace one direct taker update end-to-end:
  - `update(...)`
  - `_loadForUpdate`
  - `_updateMarket`
  - `_updateAndStore`
  - `_settle`
  - `_processOrderGlobal`
  - `_processOrderLocal`
- Trace one intent/fill path end-to-end and isolate every place `Guarantee` affects accounting.
- Confirm every `VersionLib` accumulator has the matching `CheckpointLib` realization path with the same units and signs.
- Review how `Global.update(...)` handles mid-market risk-parameter changes.
- Review `claimFee` and `claimExposure` as distinct egress paths for non-position balances.
