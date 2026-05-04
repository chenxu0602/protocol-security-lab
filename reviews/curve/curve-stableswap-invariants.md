# Curve StableSwap Invariants

## Scope
This document is primarily for **StableSwap NG** and uses legacy `curve-contract` as a secondary reference model.

The shared accounting spine across both generations is:

`balances -> xp -> D/y -> LP supply / virtual price`

NG adds materially more risk around:
- factory deployment
- asset type selection
- rate providers
- ERC4626 semantics
- rebasing-token balance drift
- views / router quote correctness

## 1. Highest-Priority NG Invariants

### 1.1 Asset type and token behavior must agree
- For each coin, configured `asset_type`, decimals, rate source, and actual token behavior must describe the same economic object.
- Plain assets must behave like plain ERC20 accounting inputs.
- Oracle assets must have a valid, correctly scaled, economically meaningful rate source.
- ERC4626 assets must preserve the convert/share assumptions used by the pool.
- Rebasing assets must be explicitly marked as such.

Why it matters:
- If asset typing is wrong, every downstream calculation can still be internally consistent while economically wrong.

Break indicators:
- a rebasing token configured as non-rebasing
- an ERC4626 asset treated as plain
- oracle direction or precision mismatch

### 1.2 `stored_rates()` must be economically coherent
- `stored_rates()` must return rates on the intended scale and in the intended direction for all assets.
- Rate refresh behavior must not silently switch units or valuation conventions between quote and execution.

Why it matters:
- `stored_rates()` is the normalization boundary feeding `xp`, `D`, swap quotes, LP mint/burn, and virtual price.

Break indicators:
- zero or tiny rates
- stale or discontinuous rates
- reverted oracle/rate-provider behavior
- ERC4626 convert semantics inconsistent with pool expectations

### 1.3 `xp` reconstruction must match the asset model
- Normalized balances `xp` must match raw balances, admin balances, rate multipliers, and stored rates under the configured asset model.
- For plain assets, raw balances should reconcile naturally with stored balances plus admin balances/dust.
- For rebasing or rate-dependent assets, reconciliation must follow the pool’s declared asset semantics rather than naive `balanceOf` assumptions.

Why it matters:
- Wrong `xp` means wrong `D`, wrong price, wrong LP supply, and wrong withdrawal amounts.

### 1.4 Stored balances and actual balances must reconcile under token semantics
- For non-rebasing plain assets, `stored_balances[i]` should track actual pool token balance except for intentional surplus, dust, donation, or admin-fee separation.
- For rebasing assets, `stored_balances[i]` may lag `balanceOf(pool)`, but sync points must be explicit and safe.
- For `exchange_received`, `balanceOf(pool) - stored_balances[i]` is treated as optimistic input and must not include unintended rebasing drift.

Why it matters:
- NG settlement depends on whether balance deltas represent real user input, passive rebasing, donation, or historical surplus.

Break indicators:
- surplus balances can be consumed by the wrong caller
- rebasing drift enters swap input
- output transfer syncs balances incorrectly

### 1.5 LP supply must remain coherent with invariant `D`
- LP minting and burning must track economically meaningful changes in `D`.
- `get_virtual_price()` should remain explainable from invariant value and LP total supply.
- Donation-sensitive changes are allowed only if they reflect the intended pool model.

Why it matters:
- LP holders price their claims through `totalSupply`, `D`, and virtual price.

Break indicators:
- LP mint over-credit
- LP burn under-charge
- virtual price jumps unexplained by balance/rate changes

### 1.6 Admin fee accounting must remain unit-consistent
- Admin fees computed in normalized `xp` space must be converted back into the correct raw token units before being added to `admin_balances[i]`.
- `admin_balances[i]` must remain denominated in the pool’s direct coin units, not underlying-expanded units.
- In metapools, admin balances for coin 1 are base-LP-token units, not base underlying coin units.

Why it matters:
- Fee accounting crosses normalized value-space and raw token-space.

Break indicators:
- admin fee is recorded in `xp` units
- metapool admin fee is interpreted as base underlying
- admin withdrawal can take LP-owned liquidity

### 1.7 Quote and execution must remain directionally consistent
- `get_dy`, `get_dx`, `calc_token_amount`, `calc_withdraw_one_coin`, and metapool underlying quote helpers should remain directionally consistent with execution under unchanged state.
- Any approximation must be covered by explicit user slippage bounds.

Why it matters:
- NG has a dedicated views layer, and routers/frontends rely on it operationally.

Break indicators:
- execution refreshes rates/fees/base-pool state in a way views do not model
- integrators can route into unsafe slippage because the view is materially optimistic

### 1.8 `exchange_received` must be impossible to misuse with rebasing assets
- If the pool contains rebasing tokens, `exchange_received` must be disabled or otherwise made safe by construction.
- Prior-transfer settlement must not let rebases or balance drift steal value.

Why it matters:
- The contract documentation explicitly treats this as a critical asset-type boundary.

### 1.9 Dynamic fee must be computed from economically comparable balances
- Off-peg / dynamic fee logic must operate on balances normalized into the same economic units.
- Fee changes around imbalance must be continuous enough that users are protected by normal slippage bounds.

Why it matters:
- NG adds dynamic fee behavior directly into trading and liquidity transitions.

Break indicators:
- fee spikes from incomparable inputs
- discontinuity around just-crossed imbalance regimes
- quote/execution fee disagreement beyond intended approximation

### 1.10 Factory deployment must reject syntactically unsafe configurations
- Factory-created pools must validate:
  - token count and decimals
  - no duplicate coins
  - fee and amplification bounds
  - asset-type and oracle array consistency at the array/length level
  - implementation / views / math wiring
  - base-pool registration assumptions for metapools

Why it matters:
- In NG, a bad deployment configuration is often equivalent to a protocol bug.

Break indicators:
- economically impossible asset-type combinations
- bad implementation index
- invalid base-pool inheritance in metapools

Economic trust assumption:
- Economic correctness of asset type choice, oracle direction, and oracle precision may remain a deployer or governance trust assumption unless the factory validates them explicitly.

### 1.11 Proportional remove-liquidity should remain the least-fragile exit
- Even if one-coin or imbalanced exits become fragile under stale rates, rebases, or quote drift, proportional `remove_liquidity` should remain the safest solvent exit path.

Why it matters:
- This is the strongest last-resort user safety invariant across Curve designs.

## 2. NG Function-Level Invariant Hooks

### 2.1 `deploy_plain_pool`
- Hook:
  - deployment parameters must define a self-consistent accounting model before the pool ever exists.
- Check:
  - assets, asset types, method ids, and oracle addresses align by index.

### 2.2 `deploy_metapool`
- Hook:
  - the metapool must inherit a valid base-pool model and not create circular or economically incompatible asset pairing.
- Check:
  - meta coin cannot invalidate the base-pool LP interpretation.

### 2.3 `add_liquidity`
- Hook:
  - LP minted should be explainable from fee-adjusted `D` growth under current rates and asset semantics.
- Check:
  - rebasing or ERC4626 behavior should not make pre/post balances diverge from the assumed deposit increment.

### 2.4 `exchange`
- Hook:
  - input received, output paid, LP fee retained, and admin fee separated must reconcile under the same normalized units used in pricing.

### 2.5 `exchange_received`
- Hook:
  - the prior transfer amount must correspond to the economic input used by swap accounting.
- Check:
  - rebasing tokens must not be able to perturb this assumption.

### 2.6 `remove_liquidity_one_coin`
- Hook:
  - one-coin withdrawal should not systematically overpay relative to proportional exit after accounting for fees and rounding.

### 2.7 `remove_liquidity`
- Hook:
  - proportional exit should remain available and explainable from balances/admin balances/rates without relying on the most fragile pricing branches.

### 2.8 `CurveStableSwapNGViews`
- Hook:
  - views are an economic API, not just convenience helpers.
- Check:
  - route selection should not become unsafe because view logic and execution logic diverge materially.

### 2.8a Views reverse quotes
- Hook:
  - `get_dx`-style helpers may be more approximate than `get_dy` when dynamic fees depend on post-trade state.
- Check:
  - reverse quotes should not be treated as exact execution guarantees unless verified against execution logic.
  - routers should not rely on optimistic reverse quotes without sufficient slippage buffer.

### 2.9 `MetaZapNG`
- Hook:
  - nested base/meta routes must preserve min-amount intent and not strand temporary balances.
- Check:
  - zap-held balances should be consumed in the nested operation, returned to the intended receiver, or explicitly treated as dust.
  - any use of `balanceOf(self)` must be checked for historical-balance contamination.
  - base-LP leftovers should be returned or re-deposited for the caller, not left in the zap.

## 3. Legacy Supplementary Invariants

These are lower priority for this document, but still useful as cross-checks.

### 3.1 Plain legacy pools: `self.balances` is the accounting base
- Raw ERC20 balance excess should usually be explainable as admin fee, dust, or donation outside ordinary LP accounting.

### 3.2 Legacy metapools: base virtual price cache must not become exploitable
- `_vp_rate` vs `_vp_rate_ro` behavior must remain directionally safe across cache-valid, cache-expired, and refreshed states.

### 3.3 Yearn-style pools: wrapper path and underlying path should differ only by intended fees, rates, and rounding
- `getPricePerFullShare()` usage must be coherent between quote and execution.

### 3.4 Compound-style pools: stored-rate quote vs current-rate execution should remain directionally consistent
- `exchangeRateStored` approximations must not create exploitable wrapped/underlying divergence.

### 3.5 Aave-style pools: live balance accounting must not confiscate LP yield
- `admin_balances[i] <= actual_balance` must always hold.
- Direct donations or passive yield entering `D` are part of the model, not automatically bugs.

### 3.6 ETH pools: reentrancy must not reopen partially updated state
- State must be finalized before ETH leaves the pool.

### 3.7 Legacy zaps: temporary custody must be zero-residual or explainable
- leftover balances, base-LP dust, and fee-on-transfer corner cases must not silently leak value.

## 4. Candidate Review Tests

### NG-first tests
- deploy a pool with inconsistent asset type / oracle setup and confirm factory rejection
- compare `stored_rates()` and execution-side rate refresh around boundary conditions
- compare quote vs execution for ERC4626, rebasing, and metapool underlying routes
- exercise `exchange_received` with and without rebasing asset declarations
- check proportional exit after donations, rebases, or rate changes
- test dynamic fee near balanced vs just-off-peg states

### Legacy backstop tests
- compare `remove_liquidity` vs `remove_liquidity_one_coin`
- compare wrapped vs underlying routes in Y / Compound / Aave pools
- compare metapool cached quote vs refreshed execution
- test zap residual balances across nested routes

## 5. Triage Guidance

Not every invariant miss is a finding by itself.

A reportable issue usually needs one of:
- value transfer
- LP dilution
- broken slippage protection
- trapped funds
- persistent quote/execution deception for integrators
- deployment of objectively unsafe pools through factory validation gaps
