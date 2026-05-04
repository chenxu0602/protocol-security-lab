# Threat Model

## Protocol Summary
The primary audit target under `/evm-playground/curve` covers the Curve StableSwap family, including both:

1. legacy `curve-contract`
   - pool templates for plain pools, metapools, lending/wrapped pools, ETH pools, and deposit/zap contracts

2. `stableswap-ng`
   - newer generalized StableSwap implementations with factory deployment, asset-type abstraction, rate-provider support, ERC4626 / rebasing / oracle-rate assets, and updated pool math / views / routing assumptions

This document focuses on `stableswap-ng` specifically. The review should treat legacy Curve and StableSwap NG as two generations of the same invariant AMM family. The shared security objective is preserving consistency between raw balances, normalized balances, invariant `D`, LP supply, virtual price, fees, external rates, and user-facing quote/execution paths.

## Scope
Primary scope:
- `contracts/main/CurveStableSwapFactoryNG.vy`
- `contracts/main/CurveStableSwapNG.vy`
- `contracts/main/CurveStableSwapMetaNG.vy`
- `contracts/main/CurveStableSwapNGMath.vy`
- `contracts/main/CurveStableSwapNGViews.vy`
- `contracts/main/MetaZapNG.vy`
- `contracts/main/CurveStableSwapFactoryNGHandler.vy`

Secondary scope:
- `LiquidityGauge.vy`
- proxy/admin wiring
- tests that encode intended behavior for factory, views, oracle, ERC4626, rebasing, exchange_received, and metapool paths

## System Model
StableSwap NG is a permissionless factory-based evolution of StableSwap with broader asset support and more explicit separation between:
- deployment-time configuration
- core pool accounting
- view/quote helpers
- metapool zap routing

Key design differences versus legacy `curve-contract`:
- no native-token support; all pools are token-only
- explicit asset-type abstraction per token
- explicit rate-provider plumbing
- ERC4626-aware and rebasing-aware accounting modes
- dynamic/off-peg fee behavior
- dedicated views contract heavily used by integrators and routers
- factory as first-class registry and deployment surface

The main trust question is no longer only “is `D` math correct?”, but also “did the factory choose the right economic interpretation for each token?”

## Pool Family Risk Matrix
| Pool family | Core asset held by pool | Main rate source | Special risk |
|---|---|---|---|
| StableSwap NG plain | direct ERC20 | decimals / stored-rate abstraction | factory parameterization, view/execution consistency |
| StableSwap NG rate-oracle | ERC20 with external rate | rate provider | stale, wrong, manipulated, or mis-scaled rate provider |
| StableSwap NG ERC4626 | vault shares | ERC4626 share-price / convert functions | donation attack, preview mismatch, withdrawal limits, rounding |
| StableSwap NG rebasing | rebasing tokens | token balance changes | balance drift without transfers, accounting sync assumptions |
| StableSwap NG metapool | meta coin + base LP token | base pool virtual price + view helpers | nested quote/execution mismatch, base-pool coupling |
| StableSwap NG factory | deployed pool instances | deployment parameters | wrong asset type, wrong rate provider, unsafe fee/A/view wiring |
| StableSwap NG views/router | off-chain or helper quoting layer | views contract + pool state | quote/execution skew, stale assumptions by routers/integrators |
| StableSwap NG metazap | temporary custody + nested pool actions | delegated to base/meta pools | leftover balances, min-amount propagation, partial settlement |

## Actors
- Factory deployer
  - permissionlessly creates pools and chooses asset types, rate providers, `A`, fee, off-peg fee multiplier, and oracle wiring
  - trust level: untrusted deployer over configuration-sensitive surfaces

- Pool LP
  - deposits supported assets and relies on LP mint/burn, virtual price, and withdrawal correctness
  - trust level: untrusted

- Swapper / router
  - uses direct pool methods, `exchange_received`, metapool routes, or helper views
  - trust level: untrusted

- Factory admin
  - controls implementation addresses, registry/admin surfaces, and fee receiver wiring
  - trust level: trusted for intent, but bounded

- Rate provider / oracle provider
  - supplies externally meaningful rates for oracle-type assets
  - trust level: partially trusted external dependency

- ERC4626 vault
  - defines share/asset conversion semantics and may impose preview, limit, or donation-sensitive behavior
  - trust level: external dependency boundary

- Rebasing token
  - can change balances without explicit pool actions
  - trust level: external dependency boundary

- Integrator / frontend / off-chain quoter
  - often relies on views instead of simulating execution directly
  - trust level: untrusted, but operationally important

## Trust Assumptions
- Asset type selection must match actual token behavior.
- Oracle precision and scaling assumptions must be correct; NG expects certain rate precision conventions.
- ERC4626 integrations are trusted only within the exact convert/preview assumptions encoded by the pool.
- Rebasing tokens are assumed to rebase in ways compatible with the declared rebasing asset type.
- Factory admin is trusted for intent, but deployment-time and upgrade-time controls must still be bounded by explicit parameter validation.

## Assets / Security Properties To Protect
- correctness of `stored_balances`, raw balances, and admin balances
- correctness of `xp`, rates, and invariant `D`
- correctness of LP mint/burn and virtual price
- correctness of dynamic fee application around off-peg states
- correctness of quote paths exposed through views and metazap helpers
- correctness of deployment-time pool configuration
- safety of `exchange_received` semantics under rebasing and non-rebasing pools
- correctness of base-pool coupling for NG metapools

## External Trust Boundaries
- ERC20 token behavior
- rebasing token balance changes
- ERC4626 `convertToAssets` and related preview semantics
- external oracle/rate-provider behavior
- factory implementation and views wiring
- base-pool virtual price and nested liquidity accounting

## StableSwap NG Specific Threat Surfaces
- Asset type abstraction
  - Pools may support plain tokens, rate-oracle tokens, rebasing tokens, ERC4626-style vault shares, or other rate-dependent assets.
  - The configured asset type must match the token’s actual balance and rate behavior.
  - Even in a permissionless factory, this is not only deployer risk: the factory should prevent configurations that are objectively unsafe, internally inconsistent, or incompatible with documented asset-type requirements.

- Rate provider correctness
  - External rate providers become part of pool pricing.
  - Wrong decimals, stale rates, manipulated rates, or reverted rate calls can distort `xp`, swaps, LP mint/burn, and virtual price.
  - Rate providers should be reviewed for return precision, revert behavior, zero or extremely small rates, non-monotonic or discontinuous rates, stale values, dependency on manipulable spot pools, and mismatch between rate direction and token denomination.

- ERC4626 integration
  - Vault share price, donation behavior, preview/convert functions, rounding, and withdrawal limits can break wrapped-vs-underlying equivalence.

- Rebasing token behavior
  - Token balances may change without explicit transfers.
  - Internal accounting must remain coherent when actual balances move independently.

- Factory deployment assumptions
  - Pool parameters, asset types, rate providers, oracle settings, amplification, fee bounds, and implementation addresses must be validated at deployment.

- Views and off-chain quote correctness
  - NG view contracts and helper functions may be used by routers, frontends, and integrators.
  - Quote/execution consistency remains security-relevant even if the core pool is safe.

- Dynamic fee / off-peg behavior
  - If NG pools apply dynamic fees or off-peg multipliers, fee growth must not create exploitable discontinuities around balance/regime changes.

## Core Accounting Anchors
- StableSwap NG rate and asset-type consistency
  - For each asset, the configured asset type, rate provider, precision multiplier, and actual token behavior must describe the same economic object.
  - A token configured as plain should not require an external rate to preserve value.
  - A token configured as rate-oracle should have a reliable and correctly scaled rate provider.
  - A token configured as ERC4626 should preserve share/asset conversion assumptions.
  - A token configured as rebasing should not break internal balance reconciliation.
  - Any mismatch can poison `xp`, `D`, LP mint/burn, swap quotes, virtual price, and user withdrawals.

- Factory deployment correctness
  - Factory-created pools must validate token count and decimals, asset type per token, rate-provider existence and scaling, fee and amplification bounds, implementation and views wiring, and oracle/rate-provider assumptions.
  - A bad deployment configuration can be equivalent to a protocol bug because all downstream accounting inherits it.

- Quote/execution consistency
  - `get_dy`, `get_dx`, `calc_token_amount`, `calc_withdraw_one_coin`, and metapool underlying quote helpers should remain directionally consistent with execution under unchanged state.
  - Any approximation must be protected by explicit user slippage bounds.
  - The views contract should be treated as an economic API: even when incorrect views do not directly mutate state, they can cause routers, integrators, and users to choose unsafe routes or unsafe slippage bounds.

- Raw-balance vs stored-balance coherence
  - For plain assets, raw token balances should reconcile naturally with `stored_balances` plus explicitly separated admin balances/dust.
  - For rebasing or rate-dependent assets, the intended reconciliation must be defined by the asset-type model rather than assumed from raw `balanceOf` alone.

- `exchange_received` safety
  - If a pool contains rebasing tokens, `exchange_received` must either be disabled or accounted for correctly.
  - Misdeclaring rebasing assets can make prior-transfer swap semantics unsafe.

## Critical State Transitions
- Factory deployment of plain pools
- Factory deployment of metapools
- Initial liquidity bootstrap
- Add / remove liquidity
- Remove liquidity one coin / imbalance
- Exchange / exchange_received
- Rate refresh and view-based quote computation
- Metapool underlying routing
- `A` ramp and fee / off-peg multiplier changes

## Main Threat Surfaces
- Misconfigured asset types
  - the most NG-specific failure mode; wrong asset interpretation corrupts every downstream calculation

- Mis-scaled or stale rate providers
  - incorrect precision or stale rate state can directly poison `xp` and LP pricing

- ERC4626 donation / rounding / preview mismatch
  - execution may diverge from convert/preview assumptions, especially under manipulated vault state

- Rebasing balance drift
  - balances may change without transfers, invalidating accounting paths that assume transfer-driven state changes

- View/execution divergence
  - routers and frontends may route based on helper views that approximate execution but do not fully reproduce runtime transitions

- Dynamic fee discontinuity
  - off-peg multipliers can create edge behavior around balance transitions where fee estimates and realized fees diverge enough to matter

- Factory or implementation wiring mistakes
  - wrong math, views, implementation, or parameter choice can create system-wide unsafe pools at deployment time

- NG metapool nested settlement
  - underlying routes and metazap flows depend on nested base-pool calculations and can inherit quote/execution skew from two layers at once

## High-Priority Review Themes
- Review factory deployment validation before pool math.
  - In NG, a correct pool implementation can still be unsafe if the factory allows invalid economic configuration.

- Review asset-type branches as distinct accounting models.
  - Plain, oracle, rebasing, and ERC4626 assets should be treated as separate security domains sharing one invariant engine.

- Review view contracts as security-relevant.
  - `CurveStableSwapNGViews.vy` is not a passive helper if routers and integrators depend on it operationally.

- Review `exchange_received` with rebasing assumptions.
  - The README and pool comments explicitly warn that misdeclared rebasing assets make this path unsafe.

- Review ERC4626 paths with donation-style thinking.
  - Share/asset conversion assumptions can fail without any bug in the pool math itself.

## Concrete Review Questions
- Can a deployer create a pool whose configured asset type is economically incompatible with the token?
- Can rate-provider scaling or decimals mismatch overstate LP value or swap output?
- Can ERC4626 donation or preview mismatch create mint/burn or swap asymmetry?
- Can rebasing balance changes desynchronize `stored_balances`, admin accounting, or quote behavior?
- Can `exchange_received` be abused when rebasing behavior is present or misdeclared?
- Can views quote a safe swap or withdrawal while execution refreshes rates, fees, or nested pool state differently?
- Can off-peg dynamic fees create exploitable edge cases around just-crossed balance regimes?
- Can metazap routes strand balances or mis-propagate `min_mint_amount` / `min_amount` assumptions across base and meta layers?

## Review Order
1. `CurveStableSwapFactoryNG.vy`
2. `CurveStableSwapNG.vy`
3. `CurveStableSwapNGViews.vy`
4. `CurveStableSwapMetaNG.vy`
5. `MetaZapNG.vy`
6. `CurveStableSwapNGMath.vy`
7. proxy/admin wiring and gauge side surfaces

## Notes From Local Test Corpus
The local tests already reveal the intended audit hotspots:
- `tests/factory/*`
  - deployment validation, pool registration, and meta/base assumptions
- `tests/pools/general/test_erc4626_swaps.py`
  - ERC4626 behavior is a first-class risk area
- `tests/pools/general/test_donation_get_D.py`
  - donation-sensitive accounting is explicitly tested
- `tests/pools/exchange/test_exchange_received.py`
  - prior-transfer swap semantics are operationally important
- `tests/pools/meta/test_get_dy_underlying_fix.py`
  - underlying quote correctness has already required regression coverage
- `tests/pools/oracle/*`
  - oracle/rate behavior is core to NG correctness

## Triage Note
Many of the surfaces above are design tradeoffs rather than findings by themselves. A reportable issue should show a concrete path that transfers value, breaks slippage protection, traps funds, misprices LP shares, or violates documented asset-type / rate-provider assumptions.
