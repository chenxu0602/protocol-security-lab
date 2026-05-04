# Curve StableSwap Function Notes

## 1. Shared StableSwap Core

### 1.1 Normalized balances: `xp`
- Purpose:
  - Convert heterogeneous pool balances into a common 1e18-like accounting space so invariant math can treat coins as economically comparable units.
- Legacy implementation:
  - Plain pools use `RATES` and `PRECISION_MUL`.
  - Y / lending pools derive rates from wrapper semantics such as `getPricePerFullShare()` or exchange-rate style methods.
  - Metapools replace the base-pool LP token rate with `_vp_rate` or `_vp_rate_ro`.
- NG implementation:
  - Uses `stored_rates()` / `_stored_rates()` and asset-type-aware rate logic.
  - Supports plain, oracle, rebasing, and ERC4626 assets.
- Review notes:
  - `xp` is where decimals, wrapper rates, oracle rates, and cached rates collapse into one economic representation.
  - If `xp` is wrong, everything downstream is wrong: `D`, `get_y`, LP mint/burn, virtual price, and fee attribution.
  - Treat `xp` construction as an accounting boundary, not just a helper.

### 1.2 Invariant: `get_D`
- Purpose:
  - Solve the StableSwap invariant that defines the pool’s total normalized liquidity under amplification parameter `A`.
- Inputs:
  - normalized balances `xp`
  - amplification `A` or `amp`
  - in NG/legacy variants, number of coins and sometimes wrapper-derived rates via `xp`
- Key assumptions:
  - balances are already economically normalized
  - iterative convergence is reached quickly and safely
  - division-by-zero or near-zero paths do not create silent mispricing
- Review notes:
  - `get_D` is the root of LP accounting and virtual price.
  - Focus on convergence, zero-balance edge cases, and whether degraded states still preserve proportional exit.
  - Donation-style balance changes matter because `D` is computed from current balances, not just tracked deltas.

### 1.3 Swap solver: `get_y`
- Purpose:
  - Given the desired post-swap balance of coin `i`, solve the resulting balance of coin `j` that preserves `D`.
- Used by:
  - swap quoting
  - swap execution
  - dynamic fee calculations built around pre/post balance estimates
- Review notes:
  - Rounding direction here determines who wins dust on every swap.
  - Check that quote and execution use economically equivalent preconditions.
  - In metapools, verify whether base-pool LP token pricing introduces stale-rate assumptions before `get_y` is called.

### 1.4 One-coin withdrawal solver: `get_y_D`
- Purpose:
  - Solve the target balance of a chosen coin after LP supply is reduced and invariant `D` is correspondingly reduced.
- Used by:
  - `calc_withdraw_one_coin`
  - `remove_liquidity_one_coin`
- Review notes:
  - This path concentrates both invariant math and fee allocation into a single-asset exit.
  - Review `dy_0 - dy` style calculations carefully because they represent the fee-bearing gap between ideal no-fee output and actual output.
  - This is usually more fragile than proportional `remove_liquidity`.

---

## 2. Legacy `curve-contract`

### 2.1 Base / 3Pool

#### `add_liquidity`
- Flow:
  - determine old balances and compute `D0`
  - construct `new_balances` from supplied amounts or actual received amounts, depending on pool variant
  - compute `D1`
  - if non-initial deposit, charge imbalance fees against the difference between ideal and actual post-deposit balances
  - mint LP tokens from fee-adjusted `D` growth
  - transfer tokens according to the pool’s settlement order
- Accounting:
  - LP mint depends on `D1 - D0` after fee-adjusted balances
  - `self.balances` become the internal accounting baseline
- Fees:
  - imbalance fees are taken during non-initial deposits; initial bootstrap has no pre-existing LPs to protect
- Review focus:
  - initial mint path vs later mint path
  - imbalance fee rounding
  - whether internal balances remain explainable relative to raw token balances and admin fee accrual

#### `exchange`
- Flow:
  - transfer in `dx`
  - compute `x`, solve `y`, derive `dy`
  - apply trade fee and update internal balances
  - transfer out `dy`
- Fee accounting:
  - fee is embedded into balance changes; the pool keeps value that later splits between LP economics and admin balances
- Review focus:
  - rounding in `dy`
  - whether quote path and execution path share the same rate/balance assumptions
  - token callback or non-standard ERC20 behavior around transfer in/out

#### `remove_liquidity`
- Flow:
  - burn LP tokens
  - distribute each coin pro-rata against pool balances
- Why no imbalance fee:
  - proportional exit is intended as the least opinionated / least fragile exit path; no asset selection means no imbalance fee logic is needed
- Review focus:
  - this should remain the safest last-resort exit
  - verify it does not depend on fragile rate refreshes or one-coin solver assumptions

#### `remove_liquidity_one_coin`
- Flow:
  - reduce `D` according to LP burn
  - use `get_y_D`
  - compute ideal output `dy_0` and actual output `dy`
  - charge fees on the difference and transfer one coin out
- `dy_0 - dy` meaning:
  - the fee-bearing spread between ideal no-fee exit and actual fee-adjusted exit
- Review focus:
  - one-coin exit should not systematically overpay vs proportional exit
  - check fee and rounding direction around `dy_0`, `dy`, and admin fee accrual

#### `remove_liquidity_imbalance`
- Flow:
  - user specifies target withdrawal amounts
  - compute new balances and reduced `D`
  - charge imbalance fees
  - burn LP up to `max_burn_amount`
- Review focus:
  - this is usually the most accounting-sensitive burn path
  - verify burn amount is conservative enough and fee logic cannot undercharge or overcharge due to rounding

#### `admin_balances` / `withdraw_admin_fees`
- Meaning:
  - represent the portion of actual pool balances that belong to admin/fee receiver rather than active LP accounting
- Review focus:
  - raw token balances minus internal balances should reconcile to admin fees, donations, or explicit dust
  - ordinary LP exits should not require undeclared reliance on accumulated admin balances

### 2.2 Metapool

#### `_vp_rate` / `_vp_rate_ro`
- Purpose:
  - price the base-pool LP token inside the metapool using base-pool virtual price
- Cache behavior:
  - `_vp_rate` refreshes storage when the cache expires
  - `_vp_rate_ro` is read-only: it returns cached value while valid, and reads live base virtual price if expired without updating storage
- Review focus:
  - stale-cache, just-expired-cache, and freshly-refreshed behavior
  - whether quote paths and execution paths are using the same economic base-LP valuation

#### `get_dy_underlying`
- Quote path:
  - may simulate wrapping into base LP, swapping meta-level balances, and unwrapping from base pool
- Approximation:
  - relies on `calc_token_amount`, `calc_withdraw_one_coin`, and cached base-pool price assumptions rather than full execution replay
- Review focus:
  - this is a classic quote/execution consistency surface
  - especially important when one side is the base-pool LP token or an underlying base asset
  - approximation is not a finding by itself; it becomes security-relevant only if user slippage bounds do not cover the divergence or if an integrator relies on the view as exact settlement

#### `exchange_underlying`
- Execution path:
  - transfer in underlying
  - if needed, add liquidity to base pool to mint base LP
  - perform meta-level swap
  - if needed, unwrap base LP through base-pool withdrawal
- Base-pool interactions:
  - execution can touch both meta and base pools, and the exact path depends on whether the swap stays inside the base pool or crosses the meta boundary
- Review focus:
  - nested settlement ordering
  - whether `_min_dy` protects the full multi-hop path
  - whether base-pool actions make execution diverge from quote materially

### 2.3 DepositTemplateMeta / Zap

#### `add_liquidity`
- Underlying-to-base-LP path:
  - pull user assets
  - if base assets are present, add liquidity to base pool
  - treat minted base LP as the metapool’s LP-side asset
  - add liquidity to the metapool and return meta LP
- Temporary custody:
  - the zap temporarily holds user assets, base LP, and final LP output
- Review focus:
  - leftover balances on the zap
  - min-amount propagation across base and meta layers
  - fee-on-transfer asset special cases such as USDT-like handling

#### `remove_liquidity_one_coin`
- Base LP unwrap:
  - if target is a base underlying asset, withdraw the metapool’s base-LP leg first, then unwrap via the base pool
- Review focus:
  - nested slippage protection
  - whether quote helpers and actual two-step withdrawal remain consistent

### 2.4 Y / Lending pool

#### `_stored_rates`
- Purpose:
  - transform wrapped balances into economically normalized rates before invariant math
- `getPricePerFullShare()`:
  - yearn-style wrapper rate becomes part of the accounting model, not just a UI reference
- Review focus:
  - stale/asymmetric wrapper rate use
  - whether wrapped and underlying views are using the same conversion conventions

#### `get_dy` vs `get_dy_underlying`
- Wrapped units vs underlying units:
  - `get_dy` prices swaps in wrapped-token space
  - `get_dy_underlying` presents user-facing quotes in underlying asset units
  - `get_dy_underlying` is an underlying-denominated quote; actual wrapping and unwrapping happen in zap or execution paths, not inside the view itself
- Review focus:
  - wrapped-vs-underlying equivalence
  - rounding and stale-rate mismatch between quote and actual unwrap/wrap execution

#### DepositTemplateY `_unwrap_and_transfer`
- Purpose:
  - after pool-level withdrawal, unwrap wrapped tokens into underlying and transfer the resulting assets to the user
- Review focus:
  - min-amount enforcement occurs after unwrap
  - leftover wrapped or underlying balances on the zap should be explainable
  - wrapper withdraw behavior is an external dependency

### 2.5 Compound-style pool

#### `_stored_rates` / `_current_rates`
- Compound-style pools hold cTokens, whose balances are share-like rather than underlying-denominated.
- `xp` is reconstructed from:
  - `cToken_balance * exchangeRate * PRECISION_MUL / PRECISION`
- `_stored_rates()` is read-only and approximates the current exchange rate from `exchangeRateStored`, `supplyRatePerBlock`, and `accrualBlockNumber`.
- `_current_rates()` calls `exchangeRateCurrent()`, which accrues Compound interest in the market and returns the current exchange rate.
- `_xp(rates)` converts internal cToken balances into normalized underlying value using those rates.
- Review focus:
  - stored-rate quote vs current-rate execution divergence
  - exchange-rate precision and decimals
  - cToken mint/redeem rounding
  - direct cToken route vs underlying route equivalence
  - whether `self.balances` and actual cToken balances reconcile after fees, donations, and redemptions

### 2.6 Aave-style pool
- What differs from Y:
  - Aave-style pools rely more on lending-token balance semantics than on a single Yearn-style share-price getter
- Balance semantics:
  - balances or effective rates may evolve independently of explicit swaps because the wrapper itself changes accounting over time
- Review focus:
  - scaled-balance / rebasing-like behavior
  - off-peg dynamic fee variants in Aave-derived legacy pools
  - whether admin fee accounting still reconciles cleanly under evolving wrapper balances

#### `add_liquidity(_use_underlying)`
- Accounting:
  - LP mint is computed from live effective balances:
    `ERC20(aToken).balanceOf(pool) - admin_balances[i]`.
  - The function constructs `new_balances` by adding `_amounts[i]` before settlement.
  - This assumes direct aToken transfer and underlying-to-Aave deposit produce the same effective pool balance increment.
- Underlying path:
  - If `_use_underlying = True`, the pool pulls underlying coins from the user and deposits them into the Aave lending pool with `onBehalfOf = self`.
  - The pool then receives aTokens, which are the actual pool assets.
- Fee model:
  - Imbalanced deposits use `_dynamic_fee`, so fee rate rises when the pool is off-peg or inventory-imbalanced.
  - Admin fee is stored explicitly in `admin_balances[i]`.
- Review focus:
  - actual aToken balance increase must match `_amounts[i]` used in pre-settlement accounting.
  - `admin_balances[i] <= ERC20(aToken).balanceOf(pool)` must always hold.
  - underlying tokens with transfer fees or non-standard behavior can break the expected increment.
  - dynamic fee should be computed from economically comparable live balances.
  - direct aToken path and underlying path should mint equivalent LP shares up to intended rounding.

#### `exchange` / `exchange_underlying`
- `exchange` settles directly in pool coins, i.e. aTokens.
- `exchange_underlying` reuses the same `_exchange` pricing path, but settles by:
  - pulling underlying coin `i`
  - depositing it into the Aave lending pool on behalf of the Curve pool
  - withdrawing underlying coin `j` from Aave directly to the user
- `get_dy` and `get_dy_underlying` are identical because the pool assumes aToken balances are denominated in underlying-equivalent units.
- Review focus:
  - underlying deposit must increase pool aToken balance by the same economic amount used in `_exchange`.
  - underlying withdrawal must consume the expected aToken amount and deliver `dy` underlying to the user.
  - fee-on-transfer underlying tokens or non-standard Aave behavior would break the precomputed accounting.
  - admin fee is recorded before settlement but reverts atomically if settlement fails.
  - direct aToken route and underlying route should be equivalent up to intended rounding and Aave semantics.

#### Live balance accounting / dynamic fee
- Unlike plain legacy pools that store `self.balances`, Aave-style pools derive effective balances from `ERC20(coin).balanceOf(pool) - admin_balances[i]`.
- This matches lending-token semantics where token balances may grow independently of explicit swaps.
- Because `_balances()` reads actual balance, direct token donations or passive lending yield can enter pool accounting immediately:
  - actual balance increases
  - `_balances()` increases
  - normalized balances increase
  - `D` and `virtual_price` can increase without an explicit swap or liquidity action
- This is a model difference from plain pools:
  - Aave-style pool: actual balance is the accounting base, admin balances are subtracted, and lending yield or donation can enter `D` automatically
  - Plain pool: `self.balances` is the accounting base, while raw-balance excess is typically admin fee, dust, or donation outside normal LP accounting until explicitly realized
- Dynamic fees are computed from normalized live balances:
  - `4 * x_i * x_j / (x_i + x_j)^2`
  - fees stay near the base fee when balances are symmetric and rise when the pool is off-peg or imbalanced.
- Review focus:
  - `admin_balances[i] <= ERC20(coin).balanceOf(pool)` must always hold.
  - admin fee accounting must not confiscate LP yield from balance-increasing tokens.
  - dynamic fee should use economically comparable balances.
  - live balance changes should not create quote/execution surprises.
  - donation-sensitive `D` / `virtual_price` changes are not automatically bugs, but they are part of the accounting model and must be reviewed as such.

### 2.7 ETH pool
- `msg.value`:
  - native ETH enters through payable paths rather than ERC20 `transferFrom`
- ETH transfer:
  - transfer out behavior and receiver callback semantics are part of execution safety
- Reentrancy:
  - dedicated tests exist for callback-based reentry into exchange and withdrawal paths
- Review focus:
  - external call ordering
  - mixed ETH/ERC20 balance updates
  - whether state is finalized before value leaves the contract

### 2.8 Curve LP token contracts
- `CurveTokenV1/V2/V3` are pool LP share tokens, not pool assets.
- Pool contracts mint LP tokens on liquidity addition and burn LP tokens on withdrawal.
- `totalSupply()` is security-critical because `get_virtual_price = D * 1e18 / totalSupply`.
- Review focus:
  - only the intended pool or minter can mint
  - `burnFrom` is only usable by the pool or minter, or otherwise respects the intended authorization model
  - `totalSupply` updates exactly with mint and burn
  - `permit`, nonce, and domain-separator logic, if present, cannot be replayed
  - LP token transferability does not bypass pool withdrawal assumptions

---

## 3. StableSwap NG

### 3.1 Factory deployment

#### `deploy_plain_pool`
- Parameters:
  - name, symbol, coins, `A`, fee, off-peg fee multiplier, EMA window, implementation index, asset types, method ids, oracle addresses
- Asset type implications:
  - the factory encodes the pool’s economic interpretation of each token at deployment time
- Review focus:
  - duplicate coin checks
  - decimals bounds
  - fee and off-peg multiplier bounds
  - whether factory prevents objectively inconsistent asset-type/oracle combinations
  - implementation index and views/math wiring must match the intended pool type

#### `deploy_metapool`
- Parameters:
  - base pool, meta coin, `A`, fee, off-peg fee multiplier, EMA window, implementation, single-asset type/oracle data for the meta coin
- Base pool assumptions:
  - the base pool must already be registered, and its LP token and asset types become part of the metapool’s accounting model
- Review focus:
  - meta coin cannot trivially conflict with base-pool assets
  - inherited base-pool assumptions can poison the metapool if registration data is wrong

### 3.2 Asset-type model
- Plain:
  - no external rate semantics beyond decimals/rate multiplier normalization
- Rate-oracle:
  - token value depends on an external rate provider with correct precision and direction
- ERC4626:
  - token value depends on share/asset conversion and can be sensitive to donation/inflation behavior
- Rebasing:
  - balances may change without explicit pool actions, so raw-balance reconciliation differs from plain assets
- Review focus:
  - asset type is an accounting declaration; if it is wrong, `stored_rates`, `xp`, LP pricing, and withdrawals can all be wrong together

### 3.3 Rate provider / stored rates
- Purpose:
  - compute `stored_rates` used to normalize balances for pricing and invariant math
- Scaling:
  - NG expects coherent rate precision and combines rate multipliers, oracle outputs, and ERC4626 conversions into the same normalization layer
- Failure modes:
  - wrong decimals
  - stale or discontinuous rates
  - zero / tiny rates
  - reverted calls
  - manipulable spot-dependent rates
- Review focus:
  - `stored_rates()` is the NG equivalent of the most fragile accounting boundary
  - review rate direction, precision, and failure behavior, not just happy-path outputs

### 3.4 Core pool functions
- `add_liquidity`
  - mint LP against `D` growth using asset-type-aware rates and dynamic-fee-aware imbalance handling
  - review: donation sensitivity, rebasing asset handling, and fee application during imbalanced deposits
- `exchange`
  - transfer in, solve swap, apply dynamic/off-peg fee, update stored/admin balances, transfer out
  - review: dynamic fee edge behavior and rate refresh timing
- `exchange_received`
  - assumes prior transfer and is intentionally disabled for rebasing-token pools
  - review: misdeclared rebasing asset types and router assumptions
- `remove_liquidity_one_coin`
  - one-asset exit through `get_y_D`, with NG asset-type-aware rates and dynamic fee behavior
  - review: fee/rounding vs proportional exit
- `remove_liquidity`
  - proportional exit path that should remain the least-fragile withdrawal mode
  - review: raw/stored balance reconciliation, rebasing-asset behavior, and whether admin/donation balances affect ordinary LP exits
- `get_virtual_price`
  - LP share-value view derived from `D` and total supply
  - review: rate/provider sensitivity and donation impact

### 3.5 Views contract
- `get_dy`
  - user/integrator-facing output quote
- `get_dx`
  - inverse quote for desired output
- `calc_token_amount`
  - LP mint/burn approximation helper
- `calc_withdraw_one_coin`
  - one-coin exit approximation helper
- Review focus:
  - treat views as an economic API
  - if views are directionally wrong, routers can choose unsafe paths or insufficient slippage bounds even if the core pool is otherwise correct
  - metapool underlying view paths are especially sensitive because they model nested base-pool behavior

### 3.6 MetaZapNG
- Temporary custody:
  - zap pulls user assets, may hold base-pool coins, base LP, and meta LP during nested execution
- Nested route:
  - base-pool add/remove liquidity and meta-pool add/remove liquidity are composed into one call path
- Slippage propagation:
  - user-provided min bounds must still be meaningful across both layers
- Review focus:
  - leftover balances on the zap
  - nested quote/execution mismatch
  - whether base and meta assumptions remain aligned when one side changes rates/fees during execution

---

## 4. Cross-Version Review Checklist

### Shared anchors
- `xp` correctness
- `D` / LP supply coherence
- quote/execution consistency
- admin fee accounting
- safe proportional exit

### Legacy-specific anchors
- metapool base virtual price cache
- yToken `getPricePerFullShare`
- zap leftover balances
- ETH reentrancy

### NG-specific anchors
- factory configuration correctness
- asset type correctness
- rate provider correctness
- ERC4626 donation / rounding
- rebasing token balance drift
- `exchange_received`
- views contract as economic API

## 5. Candidate Invariant Hooks

- `xp` reconstruction:
  - normalized balances must match raw balances, precision multipliers, and rates under the pool’s asset model

- LP supply / `D` coherence:
  - virtual price should be explainable from `D` and LP total supply

- swap settlement:
  - input received, output paid, LP fee retained, and admin fee separated must reconcile

- proportional exit safety:
  - proportional withdrawal should remain available in degraded but solvent states

- quote/execution consistency:
  - view quotes should remain directionally consistent with execution under unchanged state

- wrapper path equivalence:
  - wrapped and underlying routes should differ only by intended fees, rates, and rounding
