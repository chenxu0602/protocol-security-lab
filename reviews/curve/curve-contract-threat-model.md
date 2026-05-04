# Threat Model

## Protocol Summary
The primary audit target under `/evm-playground/curve` is `curve-contract`, not `curve-stablecoin`.

`curve-contract` is the legacy Curve StableSwap codebase: a family of Vyper pool templates and concrete pool implementations for swapping tightly correlated assets with low slippage around peg. The repository contains:
- pool templates for plain stable pools, Yearn-style lending pools, Aave-style lending pools, ETH pools, and metapools
- deployed-pool-specific instantiations under `contracts/pools/*`
- deposit/zap contracts for pools that need convenience routing
- LP token implementations under `contracts/tokens/*`

The core mechanism is the StableSwap invariant `D`, amplified by parameter `A`, with pool balances normalized into a common precision and updated through swap, mint, and burn flows. Unlike Uniswap-style constant-product pools, the security-critical surface is not just swap math, but the consistency between:
- raw token balances
- normalized balances / stored rates
- LP supply and virtual price
- admin fee accumulation
- lending-wrapper exchange rates
- metapool base-pool virtual price caching

This is therefore a **multi-flavor invariant AMM system** with several pool families sharing the same economic model but different trust boundaries.

## Scope
Primary scope:
- `contracts/pool-templates/base/SwapTemplateBase.vy`
- `contracts/pool-templates/y/SwapTemplateY.vy`
- `contracts/pool-templates/a/*`
- `contracts/pool-templates/eth/SwapTemplateEth.vy`
- `contracts/pool-templates/meta/SwapTemplateMeta.vy`
- `contracts/pool-templates/meta/DepositTemplateMeta.vy`
- concrete pool instantiations under `contracts/pools/*`
- LP token contracts under `contracts/tokens/*`

Secondary scope:
- rate calculators
- pool-specific `pooldata.json` assumptions
- zap/deposit flows used by metapools and lending pools

Out of primary scope:
- `contracts/testing/*` except as a hint for trust boundaries and regression cases

## System Model
There are five meaningful pool families in this repo:

1. Plain stable pools
   - direct ERC20 balances
   - no external yield source
   - reference implementation: `SwapTemplateBase.vy`

2. Yearn-style lending pools
   - pool holds wrapped yield-bearing tokens
   - exchange rate comes from `getPricePerFullShare()`
   - reference implementation: `SwapTemplateY.vy`

3. Aave-style lending pools
   - pool integrates lending-token balance semantics, where token balances or rates may evolve independently of explicit swaps
   - additional trust comes from aToken-style scaled balances, wrapper accounting, and lending protocol semantics

4. ETH pools
   - same invariant but with native ETH handling and payable entrypoints
   - extra reentrancy / callback risk
   - reference implementation: `SwapTemplateEth.vy`

5. Metapools
   - one asset is the LP token of a base pool
   - prices depend on cached base-pool virtual price and nested accounting
   - reference implementation: `SwapTemplateMeta.vy`

All families share the same high-level accounting loop:
- users deposit one or more assets
- balances are normalized by precision multipliers and possibly external rates
- invariant `D` determines LP mint/burn and swap quotes
- fees are split between LPs and admin accrual
- users exit proportionally, imbalanced, or one-coin

## Pool Family Risk Matrix
| Pool family | Core asset held by pool | Main rate source | Special risk |
|---|---|---|---|
| Base/plain | direct ERC20 | `RATES`, `PRECISION_MUL` | decimals/scaling mistakes, `D`/`y` math, admin fee accounting |
| Y/Yearn | wrapped yield tokens | `getPricePerFullShare()` / stored rates | stale or asymmetric wrapper rate, underlying-vs-wrapped mismatch |
| Aave | lending wrappers such as aTokens | lending-token balance semantics / wrapper-specific rate behavior | scaled-balance or rebasing-like behavior, fee accounting drift |
| Meta | meta coin plus base-pool LP token | `base_pool.get_virtual_price()` | stale base virtual price, nested settlement, quote-vs-execution mismatch |
| ETH | ERC20 plus native ETH | standard rates plus `msg.value` | reentrancy, receive/fallback behavior, ETH transfer failure |
| Zap/deposit | temporary custody only | delegated to pool and base pool | leftover balances, slippage propagation, partial settlement |

## Actors
- Pool owner / admin
  - controls admin transfer, fee changes, `A` ramping, kill switch, and unkill flow
  - trust level: trusted but highly dangerous

- Liquidity provider
  - deposits correlated assets, receives LP token, and relies on invariant-preserving mint/burn math
  - trust level: untrusted

- Swapper
  - trades through `exchange` / `exchange_underlying`
  - trust level: untrusted

- LP token holder
  - may be a passive holder distinct from the original depositor
  - trust level: untrusted

- External yield wrapper / lending protocol
  - Yearn vaults, Aave aTokens, cTokens, rate calculators
  - trust level: partially trusted external dependency

- Base pool
  - for metapools, the base pool and its virtual price are part of the price surface
  - trust level: external dependency inside the same protocol family

- Zap / deposit contract caller
  - uses convenience deposit or withdrawal routing across base and meta layers
  - trust level: untrusted

- ERC20 token contracts
  - underlying and wrapped coins, including non-standard return-value behavior and fee-on-transfer quirks like USDT
  - trust level: external dependency boundary

## Trust Assumptions
- Correlated assets are close enough in economic value for StableSwap assumptions to be meaningful.
- Wrapped/lending assets expose correct rate semantics and do not maliciously distort `balance`, `exchangeRate`, or `pricePerFullShare`.
- Base pools used by metapools preserve sane virtual price behavior.
- Admin is trusted for intent, but privileged actions must still be bounded by delay, caps, ramp limits, and explicit user exit assumptions.
- Tokens may be non-standard in return values, so safety must come from explicit balance/accounting checks rather than ERC20 idealism.

## Assets / Security Properties To Protect
- pool solvency for every supported withdrawal mode
- correctness of LP minting and burning
- correctness of `get_virtual_price()` as a share-value reference
- correctness of swap quotes `get_dy`, `get_dy_underlying`, and realized execution
- correctness of admin fee accrual without leaking LP principal
- correctness of normalized-balance math under mixed decimals and external rates
- correctness of metapool pricing relative to base-pool LP token value
- reentrancy safety for ETH and token callbacks
- exitability even in degraded states

## External Trust Boundaries
- ERC20 token behavior
- wrapped-asset exchange rate or balance semantics
- external lending protocols backing wrapped assets
- base-pool virtual price and nested swap behavior
- zap/deposit routing contracts

## Core Accounting Anchors
- Internal balance reconciliation
  - For plain ERC20-style pool coins, `ERC20(coin).balanceOf(pool) >= self.balances[i]` should generally hold.
  - For wrapped, rebasing, or lending-style assets, the equivalent reconciliation must be defined using the pool's intended balance and rate semantics.
  - Any positive difference must be explainable as admin fees, donation/dust, or intentionally unaccounted balances.
  - Ordinary LP exits must not depend on that positive difference unless it has been intentionally realized back into accounting.
- Normalized balances `xp` must remain a faithful representation of economic balances under `PRECISION_MUL`, `RATES`, or stored wrapper rates.
- LP total supply must remain coherent with invariant `D` across add/remove liquidity and one-coin withdrawal paths.
- `get_virtual_price()` must not be manipulable into overstating LP share value relative to realizable assets.
- Admin fee extraction must only capture the configured fee share and must not silently confiscate LP principal.
- Quote/execution consistency
  - View functions such as `get_dy`, `get_dy_underlying`, `calc_token_amount`, and `calc_withdraw_one_coin` should approximate the corresponding execution paths under unchanged state.
  - Any intentional approximation must be protected by `min_dy`, `min_mint_amount`, `min_amount`, or `max_burn_amount`.
- Metapool cached base virtual price must not drift far enough from current base value to create exploitable mispricing.
  - The cache boundary is itself a transition: quote paths may use read-only cached values while execution paths may refresh storage.
  - Review should compare stale-cache, just-expired-cache, and freshly-updated-cache behavior.
- Any pool family using underlying/wrapped conversions must preserve equivalence between “wrapped path” and “underlying path” up to intended fees and rounding.
- Last-resort proportional exit
  - Even if swap, one-coin withdrawal, or imbalanced withdrawal becomes unsafe due to zero balances, stale rates, or broken token behavior, proportional `remove_liquidity` should remain the least-fragile exit path.
  - It should depend on simple pro-rata balance accounting rather than the most fragile invariant-solving branches.

## Critical State Transitions
- Initial liquidity bootstrap
  - first LP mints the initial supply against zero-state invariant assumptions

- Add liquidity
  - changes balances, invariant, fee accounting, and LP supply
  - highest risk when deposit is highly imbalanced

- Remove liquidity
  - proportional withdrawal path
  - should remain the ultimate safe-exit path even if some other math becomes stressed

- Remove liquidity one coin
  - concentrates rounding and fee logic into a single-asset exit

- Remove liquidity imbalance
  - the most accounting-sensitive burn path because it mutates balances asymmetrically before solving for LP burn

- Swap / underlying swap
  - updates balances and fees using invariant-preserving math
  - especially sensitive in lending and metapool variants where quoted balances depend on external rates

- Fee update / admin transfer / `A` ramp / kill switch
  - privileged actions with delayed execution and protocol-wide economic consequences

- Base virtual price refresh
  - metapool path that decides whether cached pricing remains valid

## Main Threat Surfaces
- Invariant math and rounding errors
  - `D`, `y`, and one-coin withdrawal math can leak value if rounding direction is inconsistent across mint, burn, and swap paths.

- Admin fee leakage
  - fee accounting embedded in balance updates may over-collect or under-collect, especially on imbalanced operations.

- External rate dependence
  - Yearn/Aave/cToken-style pools trust wrapper exchange-rate semantics; bad rates directly poison swap and withdrawal math.

- Metapool base-pool coupling
  - cached base virtual price, nested liquidity operations, and split routing between meta and base layers can create stale-price, settlement mismatch, or quote-vs-execution divergence risk.

- ETH/native-asset reentrancy
  - ETH pools have payable entrypoints and explicit reentrancy tests; any external call ordering mistake can reopen state during liquidity or swap flows.

- Non-standard token semantics
  - tokens with no return value or transfer fees require balance-based handling; otherwise accounting drifts from reality.

- Zap settlement mismatch
  - deposit contracts that pull multiple assets, optionally route through a base pool, and then return LP tokens are vulnerable to partial-settlement, stale-min-amount, and fee-asset corner cases.

- Governance action abuse
  - `A` ramps, fee changes, kill switch, or ownership transfer can extract value or trap users if constraints are insufficient.

## High-Priority Review Themes
- Review imbalanced deposit/withdraw math before symmetric paths.
  - That is where admin fee accounting and rounding direction are most likely to transfer value silently.

- Review wrapped-vs-underlying equivalence.
  - Lending pools should not let users arbitrage between wrapped and underlying entrypoints due to stale or asymmetric rate usage.

- Review metapool stale-cache assumptions.
  - The tests already target rate caching; treat base virtual price freshness as a first-order economic invariant and compare stale-cache to refresh-on-execution behavior.

- Review ETH pool reentrancy boundaries.
  - The local test suite contains dedicated reentrancy tests, which means this is a known design pressure point rather than a hypothetical one.

- Review zap contracts as independent accounting surfaces.
  - They are not merely UX wrappers; they perform nested pool actions and temporary custody of user funds.

## Concrete Review Questions
- Can any add/remove-liquidity path mint or burn too many LP tokens due to precision loss?
- Can a one-coin exit be systematically favored over a proportional exit in a way that leaks value?
- Can admin fees accumulate in a way that reduces LP claims more than configured?
- Can wrapper rate changes or rate-calculator behavior make `get_dy_underlying` diverge materially from realizable execution?
- Can a metapool use stale `base_virtual_price` long enough to create profitable mispricing?
- Can quote functions remain directionally safe around cache-expiry boundaries, or does execution refresh create exploitable quote/execution skew?
- Can nested base-pool interactions in zap flows leave stranded balances or let users bypass slippage checks?
- Can any token callback or ETH receive hook reenter during swap or withdrawal before state is finalized?
- Can `A` ramping or fee changes create a discontinuity that lets a privileged actor extract value around scheduled transitions?
- If one coin in a pool becomes broken or non-transferable, does proportional withdrawal remain a credible last-resort exit?

## Review Order
1. `SwapTemplateBase.vy`
2. `SwapTemplateMeta.vy`
3. `DepositTemplateMeta.vy`
4. `SwapTemplateY.vy`
5. `a/*`
6. `SwapTemplateEth.vy`
7. `CurveTokenV1/V2/V3.vy`
8. concrete pool overrides and `pooldata.json` assumptions

## Notes From Local Test Corpus
The local tests already point to the right stress areas:
- `tests/pools/eth/test_reentrancy.py`
  - explicit callback-based attempts to reenter `exchange` and withdrawal paths
- `tests/pools/meta/test_rate_caching.py`
  - validates quote stability under cached-rate assumptions
- `tests/pools/aave/test_atoken_balances.py`
  - indicates wrapper balance semantics are security-relevant
- `tests/pools/aave/test_modify_fees_aave.py`
  - flags fee logic as a lending-pool-specific concern
- `tests/forked/test_insufficient_balances.py`
  - suggests real-token balance behavior can diverge from idealized mocks

These tests should shape review priority:
- reentrancy and external call ordering
- wrapper-rate correctness
- admin fee accounting
- metapool cache integrity
- and safe exit behavior under non-ideal token semantics

## Triage Note
Many of the surfaces above are design tradeoffs rather than findings by themselves. A reportable issue should show a concrete path that transfers value, breaks user slippage protection, traps funds, or violates documented accounting guarantees.
