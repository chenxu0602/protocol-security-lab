# Monetrix Function Notes

## MonetrixVault

### Vault Priority Lens
- If focusing only on `MonetrixVault.sol`, the two highest-signal review tracks are:
- `bridge / redemption / local liquidity`
- `settle / yield routing / reservation logic`
- The key question is not just whether the protocol is solvent on `totalBackingSigned()`.
- The key question is whether Vault still retains enough EVM-side USDC for user-facing redemption flows while bridging and settling yield.
- In other words:
- solvency and local redeemability are different properties
- many valuable bugs here will be liveness or reservation bugs, not direct theft bugs

### `deposit(uint256 amount)`
- User deposits EVM-side USDC and receives USDM 1:1.
- Enforces config min/max deposit bounds and optional max TVL cap.
- Transfers USDC in before minting USDM.
- Does not consult Accountant or backing before minting; undercollateralized-state deposits are allowed by design.
- Review focus:
- Is minted amount based on requested amount rather than actual tokens received?
- Are pause and cap checks sufficient?
- Does any weird-token behavior matter, or is plain USDC assumed?

### `requestRedeem(uint256 usdmAmount)`
- User transfers USDM to the Vault.
- Increases `RedeemEscrow.totalOwed`.
- Creates a cooldowned redeem request.
- Does not burn USDM yet.
- Critical accounting point: a separate USDC obligation is created while `USDM.totalSupply()` is still unchanged.
- Review focus:
- Does this create any phantom-surplus window?
- Are queue storage and `totalOwed` always synchronized?
- Can obligations be created without the USDM actually moving into Vault custody?

### `claimRedeem(uint256 requestId)`
- Only request owner can claim after cooldown.
- Deletes request, burns Vault-held USDM, then pays USDC from `RedeemEscrow`.
- `RedeemEscrow.payOut` reverts on insufficient balance, so there is no silent haircut.
- Review focus:
- Is delete-before-burn-before-pay ordering safe?
- Can a request be claimed twice?
- Can users become stuck because escrow funding is locally illiquid even when protocol backing is positive?

### `keeperBridge(BridgeTarget target)`
- Operator bridges EVM USDC to HyperCore.
- Uses `netBridgeable()` rather than raw Vault balance.
- Increments `outstandingL1Principal`.
- Destination is code-bounded to `address(this)` or configured `multisigVault`.
- Review focus:
- Does `netBridgeable()` reserve enough for redemption shortfall and bridge retention?
- Can normal bridging worsen bank-run conditions due to formula error?
- Can `outstandingL1Principal` drift from economically relevant principal?

### `bridgePrincipalFromL1(uint256 amount)`
- Bridges back principal from L1 to EVM.
- Requires `amount <= redemptionShortfall()` and `amount <= outstandingL1Principal`.
- Decrements `outstandingL1Principal` before sending bridge action.
- Review focus:
- Is principal separation from yield preserved?
- Can counter drift block legitimate principal returns?
- Does `_sendL1Bridge` correctly check actual L1 USDC availability?

### `bridgeYieldFromL1(uint256 amount)`
- Bridges back yield from L1 without touching `outstandingL1Principal`.
- Bounded by `yieldShortfall()`.
- Review focus:
- Is `yieldShortfall()` computed conservatively relative to EVM-side reservations?
- Can realized yield be bridged back under the wrong bucket?

### `executeHedge(uint256 batchId, HedgeParams params)`
- Sends spot-buy and perp-short actions through `ActionEncoder`.
- If PM is enabled, registers the supplied spot token in Accountant.
- Uses `perpToSpot(perpAsset)` for registration, not `spotAsset` pair id.
- Review focus:
- Pair-asset vs token-index vs perp-index correctness.
- Whether PM registration can go stale or miss newly supplied assets.
- Any partial-fill / routing semantics that leave backing under- or over-counted.

### `closeHedge(CloseParams params)`
- Sends spot-sell and perp-close actions.
- No direct accounting mutation besides the L1 action side effects.
- Review focus:
- Whether closing can move value between domains that Accountant counts twice or misses.

### `repairHedge(uint256 positionId, RepairParams params)`
- Sends a single-leg repair order for partial-fill cleanup.
- Accepts either perp or spot pair asset depending on `isPerp`.
- Review focus:
- Asset-domain validation.
- Can repair actions accidentally expand exposure rather than neutralize it?

### Hedge Audit Checklist

#### 1. Asset-domain mixups
- `perpAsset` is perp index.
- `spotAsset` in hedge paths is `spotPairAssetId`, not `spotTokenIndex`.
- PM / Accountant supplied registry uses `spotTokenIndex`.
- Review focus:
- Does `executeHedge` always derive the correct `spotToken` from `perpToSpot(perpAsset)`?
- Is any path accidentally using pair id where token index is required?
- Does `repairHedge` validate the correct domain for spot-leg repair?

#### 2. Two legs are not economically atomic
- `executeHedge` sends buy-spot then short-perp.
- `closeHedge` sends sell-spot then close-perp.
- Real HyperCore execution may leave partial fill or one-leg-only state.
- Review focus:
- Does the protocol ever assume "execute succeeded" means already delta-neutral?
- Can intermediate states make backing look safer than it is?
- Are residual single-leg exposures expected to be cleaned only by operator repair?

#### 3. `repairHedge` may be able to expand exposure
- `repairHedge` is a single-leg action with keeper-chosen `isBuy`, `reduceOnly`, `size`, and `isPerp`.
- `residualBps` is logged but not enforced on-chain.
- Review focus:
- Can a nominal "repair" action create larger net exposure rather than reduce residual?
- Is this merely trusted-operator policy, or can it break accounting assumptions under normal workflows?

#### 4. PM autosupply vs Accountant registry
- Under PM, spot acquired during hedge may auto-supply into `0x811`.
- `executeHedge` registers that supplied token in Accountant.
- Review focus:
- Is autosupply guaranteed, or can registration get ahead of actual state?
- Can wrong or stale registration make `totalBackingSigned()` revert or miscount?

#### 5. `closeHedge` leaves supplied registry intact
- Closing a hedge does not remove supplied entries.
- Registry cleanup relies on separate Accountant management.
- Review focus:
- Does stale registry only cause conservative undercount / fail-closed behavior?
- Or can it create dangerous overcount or liveness failure?

#### 6. Backing double-count risk
- Hedge lifecycle changes which HyperCore domains hold value:
- account value
- spot balances
- supplied balances
- HLP / other domains
- Review focus:
- Could spot/perp/supplied state after execute/close/repair be counted twice by Accountant?
- Are any of these domains already embedded inside `accountValueSigned()`?

#### 7. Size / truncation / precision boundaries
- Hedge params rely on `uint64 size` and price fields.
- `ActionEncoder` writes raw HyperCore payloads with these values.
- Review focus:
- Are unit conventions consistent across execute/close/repair?
- Can partial-fill residuals become unrepairable dust because of rounding or minimum lot sizes?
- Are there any `uint64` boundary conditions that silently distort intent?

#### 8. `reduceOnly` semantics may differ across spot and perp
- Code comments already note spot reduce-only behavior can differ from perp behavior on HyperCore.
- Review focus:
- Could keeper believe a repair/close action only reduces exposure while HyperCore treats it as fresh opening flow?
- Does this asymmetry matter for spot-leg repair and close?

#### 9. Operator-supplied price parameters
- Hedge functions rely on operator-provided spot/perp/repair prices.
- Review focus:
- Wrong prices are not automatically a bug because operator is trusted.
- The real issue is whether bad but allowed price inputs can push the system into dangerous accounting-visible intermediate states.

#### 10. Events are not the source of truth
- `HedgeExecuted`, `HedgeClosed`, and `HedgeRepaired` only log intent-level metadata.
- Actual economic state lives on HyperCore, not in Solidity storage.
- Review focus:
- Do not infer final position state solely from emitted events.

### `depositToHLP(uint64 usdAmount)`
- Sends a HyperCore vault deposit into HLP.
- Requires `hlpDepositEnabled`.
- Review focus:
- HLP equity is later counted at full mark value.
- Confirm this action cannot make backing appear instantly liquid on EVM when it is not.

### `setHlpDepositEnabled(bool enabled)`
- Instant operator toggle for future HLP deposits only.
- Review focus:
- Mostly operational; low bug surface unless downstream logic assumes HLP deposits are always possible.

### `withdrawFromHLP(uint64 usdAmount)`
- Reads HLP equity via precompile.
- Enforces `usdAmount <= equity` and HLP lock expiry.
- Sends HLP withdraw action.
- Review focus:
- Lock semantics are in ms-epoch; unit mismatch would be serious.
- If precompile semantics differ, liveness can break or value can be mis-modeled.

### `supplyToBlp(uint64 token, uint64 l1Amount)`
- Sends BLP supply action.
- Registers supplied token in Accountant.
- For non-USDC, requires spot token to be whitelisted and derives perp index from config.
- Review focus:
- Supplied registry freshness and correctness.
- Token-index / perp-index mapping accuracy.
- Repeated or stale registrations causing revert/undercount/double-count issues.

### `withdrawFromBlp(uint64 token, uint64 l1Amount)`
- Sends BLP withdraw action.
- Does not deregister supplied slot.
- Review focus:
- Stale registry entries are intentional but can affect read behavior.
- Need to understand whether stale entries only cause conservative reads or can cause harder failures.

### `settle(uint256 proposedYield)`
- Operator-side atomic yield settlement entrypoint.
- Reserves only redemption shortfall from EVM USDC before allowing settlement.
- Calls `Accountant.settleDailyPnL`.
- Transfers settled USDC into `YieldEscrow`.
- Review focus:
- Interaction between EVM liquidity and accounting surplus.
- Why `bridgeRetentionAmount` is excluded here and whether that is safe.
- Whether any normal state transition lets settled yield exceed realized and distributable surplus.

### `distributeYield()`
- Pulls all USDC from `YieldEscrow`.
- Splits into user, insurance, and foundation share.
- For user share, mints matching USDM and injects it into `sUSDM`.
- If `sUSDM.totalSupply() == 0`, reroutes user share to foundation to avoid empty-vault capture.
- Review focus:
- USDM minting here is safe only if matched by already-realized USDC.
- Split math must not underflow or strand dust incorrectly.
- Empty-sUSDM reroute must not create value leakage or accounting mismatch.

### `fundRedemptions(uint256 amount)`
- Moves EVM USDC from Vault to `RedeemEscrow`.
- Uses current shortfall as cap; `amount == 0` means "fund full shortfall".
- Review focus:
- Bank-run liveness.
- Whether partial funding can interact badly with claiming order.

### `reclaimFromRedeemEscrow(uint256 amount)`
- Pulls excess USDC back from `RedeemEscrow`.
- `RedeemEscrow` itself prevents reclaim below `totalOwed`.
- Review focus:
- Whether reclaim can still interfere with short-term claim liveness even if obligations remain fully collateralized.

### `pause()` / `unpause()`
- Guardian-controlled OZ pause.
- Blocks user flows and mixed paths such as `deposit`, `claimRedeem`, `keeperBridge`, `settle`, `distributeYield`.
- Review focus:
- What remains callable under `paused` and whether that creates asymmetric liveness issues.

### `pauseOperator()` / `unpauseOperator()`
- Independent operator pause switch.
- Blocks hedge/HLP/BLP/bridge/yield/escrow-routing functions.
- Review focus:
- Difference from main pause is material; do not assume they protect the same surface.

### `emergencyRawAction(bytes data)`
- Governor emergency HyperCore action bypassing pause flags.
- Review focus:
- Explicit emergency power; only valid issue shape is bypass of a hard accounting invariant, not mere broad authority.

### `emergencyBridgePrincipalFromL1(uint256 amount)`
- Governor version of principal bridge-back.
- Bypasses pause flags.
- Review focus:
- Same principal accounting questions as operator path.

### Setter cluster
- `setAccountant`
- `setMultisigVault`
- `setMultisigVaultEnabled`
- `setRedeemEscrow`
- `setYieldEscrow`
- `setBridgeRetentionAmount`
- `setPmEnabled`
- Review focus:
- These shape trust boundaries and accounting domains.
- High-signal issues are missing invariant enforcement, stale domain inclusion, or domain-mixup bugs.

### `netBridgeable()`
- EVM-side bridgeable balance after reserving redemption shortfall and bridge retention.
- Core liveness formula for `keeperBridge`.

### `redemptionShortfall()`
- Current `RedeemEscrow` underfunding.
- Direct bank-run stress indicator.

### `yieldShortfall()`
- Positive-accounting-surplus amount that is not yet locally available as EVM USDC after reservations.
- Review focus:
- Important distinction between solvency and immediate EVM liquidity.

### `canKeeperBridge()`
- Simple readiness view for bridging.
- Depends on interval and `netBridgeable() > 0`.

### Vault Top Review Paths
- `keeperBridge -> requestRedeem -> fundRedemptions -> claimRedeem`
- `requestRedeem -> settle -> claimRedeem`
- `requestRedeem -> partial funding -> settle -> claim`
- `keeperBridge -> requestRedeem -> bridgePrincipalFromL1`
- `bridgeYieldFromL1 -> settle -> distributeYield`
- Review focus:
- Do these interleavings preserve enough EVM USDC for redemptions?
- Can the protocol stay economically solvent while becoming locally illiquid?
- Can a normal yield-settlement path consume USDC that should have remained effectively reserved for redemption recovery?

## MonetrixAccountant

### `totalBackingSigned()`
- Main economic backing view.
- Includes Vault and RedeemEscrow EVM USDC plus L1 backing for Vault and optional `multisigVault`.
- Excludes `YieldEscrow` and `InsuranceFund` by design.
- Review focus:
- Highest-priority surface in the protocol.
- Need exact once-only counting across account value, spot USDC, supplied balances, spot hedge balances, and HLP equity.

### `_readL1Backing(address account, SuppliedAsset[] suppliedList)`
- Aggregates one HyperCore account's backing.
- Starts from signed perp account value, then adds spot USDC, registered supplied balances, whitelisted spot hedge notionals, and HLP equity.
- Review focus:
- Does `accountValueSigned` already include any of the later-added components?
- Are supplied balances distinct from spot balances?
- Is HLP equity independent from margin/account value?

### `totalBacking()`
- Clamps signed backing at zero.
- Convenience view only; internal reasoning should use signed version.

### `surplus()`
- Defined as `totalBackingSigned() - USDM.totalSupply()`.
- Review focus:
- Purely economic view; not sufficient by itself for local payout/liquidity safety.

### `distributableSurplus()`
- `surplus()` minus redemption shortfall.
- Explicit fix for redeem-window phantom yield.
- Review focus:
- One of the most important formulas in the system.
- Any missed liability or double-counted backing here can directly overstate yield.

### `settleDailyPnL(uint256 proposedYield)`
- Only-Vault yield gate with 4 checks:
- settlement initialized
- minimum interval elapsed
- `proposedYield <= distributableSurplus()`
- `proposedYield <= annualized cap`
- Updates `lastSettlementTime` and cumulative `totalSettledYield`.
- Review focus:
- Highest-priority bug surface.
- Need to confirm no bypass of gates 1-4 and no arithmetic / unit issues in annualized cap.

### `setConfig(address _config)`
- Sets config contract used for whitelist and APR cap.
- Review focus:
- Wrong config can change the entire read surface; issue shape is missing guardrail, not trusted-governor misuse.

### `setMinSettlementInterval(uint256 interval)`
- Governor-tunable lower-bound between settlements.
- Review focus:
- Mostly parameter policy, unless bounds permit clearly unsafe normal operation.

### `notifyVaultSupply(uint64 spotToken, uint32 perpIndex)`
- Registers a Vault-side supplied slot.
- Idempotent by token.
- Review focus:
- Can stale `perpIndex` or wrong token registration poison read-side accounting?

### `addMultisigSupplyToken(uint64 spotToken)`
- Operator registers multisig supplied token.
- Derives perp index from config and rejects non-whitelisted spot tokens.
- Review focus:
- Operator-maintained registry is a real accounting dependency despite operator trust.

### `removeSuppliedEntry(bool isMultisig, uint256 index)`
- Swap-and-pop removal from supplied registry.
- Intended to be conservative: removal should reduce measured backing, not increase it.
- Review focus:
- Confirm that removal cannot hide obligations while still permitting dangerous downstream actions.

### `initializeSettlement()`
- One-time opening of settlement pipeline.
- Requires config to be set.
- Review focus:
- Gate 1 anchor; settlement before initialization must be impossible.

## MonetrixConfig

### `setYieldBps(uint256 userBps, uint256 insuranceBps)`
- Sets user and insurance split; foundation gets residual to 10000.
- Review focus:
- Sum bounded to 10000.
- Economic policy, but arithmetic correctness still matters for distribution.

### `setDepositLimits(uint256 min, uint256 max)`
- Sets deposit bounds.
- Review focus:
- Basic parameter guardrails only.

### `setMaxTVL(uint256 maxTVL)`
- Optional total supply cap.

### `setBridgeInterval(uint256 interval)`
- Controls minimum time between `keeperBridge` calls.

### `setCooldowns(uint256 redeemCooldown, uint256 unstakeCooldown)`
- Defines async exit timing for Vault redeem queue and `sUSDM` unstake queue.
- Review focus:
- Mostly policy; functional concern is that multiple queues rely on these values.

### `setInsuranceFund(address addr)` / `setFoundation(address addr)`
- Updates destinations for non-user yield shares.
- Review focus:
- Destination binding is trusted-governor policy unless a missing invariant makes normal routing unsafe.

### `setMaxYieldPerInjection(uint256 amount)`
- Caps a single `sUSDM.injectYield`.
- Defense-in-depth against oversized user-share distribution.

### `setMaxAnnualYieldBps(uint256 bps)`
- Sets Gate 4 APR cap with hard upper bound.
- Review focus:
- Bound enforcement matters because this is the on-chain brake on keeper-reported yield velocity.

### `addTradeableAsset(...)` / `addTradeableAssets(...)`
- Adds whitelist tuples binding `perpIndex`, `spotIndex`, and `spotPairAssetId`.
- Review focus:
- Hyperliquid has multiple identifier spaces; these mappings are safety-critical.

### `removeTradeableAsset(uint32 perpIndex)`
- Removes whitelist entry and mapping state.
- Review focus:
- Removal can descope accounting for still-held assets; this is a real audit question because backing composition depends on whitelist iteration.

## sUSDM

### `totalAssets()`
- Defined as USDM balance held directly by `sUSDM`.
- Excludes `sUSDMEscrow`.
- Review focus:
- Core source of exchange-rate truth for active shares.

### `deposit(uint256 assets, address receiver)` / `mint(uint256 shares, address receiver)`
- Normal ERC-4626 entrypoints gated by pause and reentrancy guard.
- Review focus:
- Standard wrapper entry logic; main protocol-specific concern is interaction with future yield injection.

### `withdraw(...)` / `redeem(...)`
- Hard-revert; async cooldown path must be used instead.
- Review focus:
- Important integrator behavior; prevents false assumptions from generic ERC-4626 users.

### `maxDeposit` / `maxMint`
- Return 0 while paused.
- Integrator-facing correctness helpers.

### `maxWithdraw` / `maxRedeem`
- Always return 0 because synchronous exits are unsupported.

### `cooldownShares(uint256 shares)`
- Burns shares immediately.
- Computes assets via `convertToAssets`.
- Increases `totalPendingClaims`.
- Pulls exact USDM into `sUSDMEscrow`.
- Creates cooldown request.
- Review focus:
- Exchange-rate neutrality.
- Physical isolation invariant.
- No future yield for cooled-down shares.

### `cooldownAssets(uint256 assets)`
- Burns shares computed via `previewWithdraw` for an exact asset target.
- Same escrow-isolation mechanics as `cooldownShares`.
- Review focus:
- Upward rounding in `previewWithdraw` can create systematic drag; quantify whether it is expected and bounded.

### `claimUnstake(uint256 requestId)`
- Only request owner can claim after cooldown.
- Deletes request, decreases `totalPendingClaims`, releases USDM from escrow.
- Review focus:
- Single-claim semantics.
- `totalPendingClaims` must stay equal to escrow balance.

### `injectYield(uint256 usdmAmount)`
- Only Vault can inject.
- Transfers USDM from Vault into `sUSDM`.
- Requires nonzero staker supply and per-injection cap.
- Review focus:
- Core rate-increase path.
- Empty-vault injection must be impossible.

### `setConfig(address config)`
- Governor updates config dependency.

### `setEscrow(address escrow)`
- One-time binding of `sUSDMEscrow`.
- Grants infinite USDM allowance to escrow.
- Review focus:
- Must bind to escrow whose immutable `sUSDM()` matches this contract.

### `setVault(address vault)`
- One-time binding of Vault authorized to inject yield.

### `pause()` / `unpause()` / `_update(...)`
- Guardian pause and paused-transfer enforcement.
- Review focus:
- Pause blocks transfers as well as cooldown/claim entrypoints.

## USDM

### `setVault(address vault)`
- One-time Vault binding.
- Review focus:
- Core trust anchor for mint/burn authority.

### `mint(address to, uint256 amount)`
- Only Vault can mint.
- Used for deposits and user-share distribution.

### `burn(uint256 amount)`
- Only Vault can burn its own balance.
- Review focus:
- Works because `requestRedeem` transfers user USDM into Vault first.

### `pause()` / `unpause()` / `_update(...)`
- Guardian-controlled transfer pause.

## RedeemEscrow

### `addObligation(uint256 amount)`
- Increases `totalOwed`.
- Called on `requestRedeem`.

### `payOut(address recipient, uint256 amount)`
- Requires full balance coverage.
- Decreases `totalOwed` then transfers USDC.
- Review focus:
- No silent haircut invariant.

### `reclaimTo(address to, uint256 amount)`
- Allows only excess USDC above `totalOwed` to be reclaimed.
- Review focus:
- Protects obligations, but not necessarily user liveness timing under stress.

### `shortfall()`
- `max(totalOwed - balance, 0)`.
- Important input to `distributableSurplus`, `netBridgeable`, and funding logic.

## YieldEscrow

### `pullForDistribution(uint256 amount)`
- Only Vault can pull USDC back for distribution.
- Holds settled-but-undistributed yield.
- Review focus:
- This balance is intentionally excluded from backing.

### `balance()`
- Simple USDC balance view.

## sUSDMEscrow

### `deposit(uint256 amount)`
- Only `sUSDM` can pull USDM into escrow.
- Review focus:
- This escrow is intentionally dumb and immutable; accounting correctness lives in `sUSDM`.

### `release(address to, uint256 amount)`
- Only `sUSDM` can release claim amount to user.

## InsuranceFund

### `deposit(uint256 amount)`
- Anyone can deposit USDC.
- In practice receives insurance-share yield from Vault.

### `withdraw(address to, uint256 amount, string reason)`
- Governor-only withdrawal path.
- Recovery backstop under solvency stress.
- Review focus:
- Trusted path; issue shape would be missing invariant enforcement, not mere broad authority.

## PrecompileReader

### Read wrappers
- `spotBalance`
- `vaultEquity`
- `oraclePx`
- `accountValueSigned`
- `suppliedBalance`
- `spotPx`
- `perpAssetInfo`
- `tokenInfo`
- All fail closed on short / failed responses.
- Review focus:
- Highest-signal library surface.
- Any decode-length mistake, unit misunderstanding, or zero-price handling error can poison all higher-level accounting.

### Conversion helpers
- `spotUsdcEvm`
- `suppliedUsdcEvm`
- `spotNotionalUsdcFromPerp`
- `suppliedNotionalUsdcFromPerp`
- Review focus:
- Compose raw precompile values with `TokenMath`.
- Confirm decimal assumptions and signed/unsigned boundaries.

## ActionEncoder

### Hedge action senders
- `sendBuySpot`
- `sendShortPerp`
- `sendSellSpot`
- `sendClosePerp`
- `sendRepairAction`
- All funnel through `_sendLimitOrder`.
- Review focus:
- Wire format correctness.
- Reduce-only semantics differ across spot/perp.
- Asset-id correctness is critical.

### Vault / BLP / bridge senders
- `sendVaultDeposit`
- `sendVaultWithdraw`
- `sendSupply`
- `sendWithdrawSupply`
- `sendSpotSend`
- `sendBridgeToL1`
- Review focus:
- Unit expectations differ across functions.
- `sendBridgeToL1` and `sendSpotSend` rely on `TokenMath` conversion to L1 8dp.
- `uint64` truncation / overflow boundaries matter.

## TokenMath

### `usdcEvmToL1Wei` / `usdcL1WeiToEvm`
- Core USDC 6dp <-> 8dp rescaling.
- Review focus:
- Exactness and overflow behavior.

### `evmToL1Wei` / `l1WeiToEvm`
- Generic HIP-1 token conversion using `evmExtraWeiDecimals`.
- Review focus:
- Sign handling of `evmExtraWeiDecimals`.
- Floor rounding direction.

### `spotNotionalUsdcFromPerpPx` / `spotNotionalUsdcFromSpotPx`
- Converts token balances plus raw oracle prices into 6dp USDC notionals.
- Review focus:
- Decimal exponent formulas are safety-critical.

### `usdcSpotWeiToPerp` / `usdcPerpToSpotWei`
- L1 spot/perp USDC rescaling helpers.

## Governance Helpers

### `MonetrixGovernedUpgradeable`
- Shared role checks for `onlyGuardian`, `onlyOperator`, `onlyGovernor`, `onlyUpgrader`.
- Review focus:
- Thin wrapper; main importance is that all protocol authority converges here.

### `MonetrixAccessController`
- UUPS ACL holding role assignments.
- Review focus:
- Mostly standard access-control infrastructure; lower priority than accounting surfaces.

## Cross-Function Flows

### Flow 1 Deposit -> sUSDM Stake -> Yield Injection

```text
Vault.deposit
    USDC moves user -> Vault
    USDM minted to user

sUSDM.deposit
    USDM moves user -> sUSDM
    sUSDM shares minted to user

Vault.settle
    USDC moves Vault -> YieldEscrow

Vault.distributeYield
    USDC moves YieldEscrow -> Vault
    userShare USDM minted to Vault
    USDM injected Vault -> sUSDM
```

Review focus:

- User-share distribution increases `USDM.totalSupply()`.
- This is safe only if the corresponding USDC yield has already been realized and isolated.
- If `settle` can operate on phantom surplus, `distributeYield` can mint yield-bearing USDM without true backing.

### Flow 2 Deposit -> RequestRedeem -> FundRedemptions -> ClaimRedeem

```text
Vault.deposit
    user receives USDM

Vault.requestRedeem
    USDM moves user -> Vault
    RedeemEscrow.totalOwed increases
    request is recorded
    USDM supply unchanged

Vault.fundRedemptions
    USDC moves Vault -> RedeemEscrow up to shortfall

Vault.claimRedeem
    request is deleted
    Vault-held USDM is burned
    RedeemEscrow pays USDC to user
    RedeemEscrow.totalOwed decreases
```

Review focus:

- There is no supply reduction at request time.
- Queued redemption liability therefore remains inside `USDM.totalSupply()`.
- Any valid redemption-surplus issue now needs a subtler sequence than simply "`totalOwed` is not subtracted."

### Flow 3 Deposit -> `keeperBridge` -> `requestRedeem` -> `bridgePrincipalFromL1`

```text
Vault.deposit
    Vault holds EVM USDC

keeperBridge
    excess EVM USDC moves toward HyperCore
    outstandingL1Principal increases

requestRedeem
    user creates USDC payout obligation

fundRedemptions / bridgePrincipalFromL1
    protocol must restore EVM liquidity for claim
```

Review focus:

- Solvency and local EVM liquidity are different.
- The protocol can be solvent on `totalBackingSigned()` while still locally illiquid for redemption.
- The key question is whether normal bridge formulas preserve enough local liquidity or provide a bounded recovery path.

### Flow 4 Execute Hedge -> Supply To BLP -> Accountant Read

```text
executeHedge
    spot/perp actions sent through ActionEncoder
    Accountant notified of supplied spot token if PM enabled

supplyToBlp
    supplied asset action sent
    supplied registry updated

Accountant.totalBackingSigned
    supplied registry controls which supplied balances are read
```

Review focus:

- Registry state becomes part of accounting truth.
- A stale or wrong registry entry can cause overcount, undercount, or fail-closed reverts.
- Need to distinguish conservative undercount from dangerous overcount.
