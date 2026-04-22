# Threat Model

## Protocol Summary
Panoptic (v2 core) is a noncustodial, permissionless perpetual options protocol built on top of Uniswap V3/V4 pools. Users create option positions as tokenized contracts (ERC-1155) referencing a specific Uniswap pool and option “legs” encoded in a TokenId. LP-style collateral is deposited into CollateralTracker vaults per underlying token; option writers are required to post collateral and remain solvent against mark/ITM exposure derived from Uniswap price/oracle observations. Premiums/fees and intrinsic value are settled continuously/instantaneously via interactions with Uniswap (and a shared/separate SFPM/position manager). A Guardian role can trigger safety modes / halt certain actions, influencing oracle usage and risk parameters.

Core economic mechanism: mint/burn multi-leg option positions (short/long) whose payoff is a function of Uniswap price (tick) and time/observation windows; enforce full collateralization via risk checks and liquidation/force-exercise when collateral is insufficient; account for collateral shares and owed amounts with strict conservation across ERC20 vault balances, ERC1155 position supply, and Uniswap fee/intrinsic settlement.

## Actors
- Trader (taker)
  - Creates option exposure by minting/burning option positions; may be net long or short across legs.
  - trust level: untrusted
- Option writer
  - Sells options by minting short legs; posts collateral in CollateralTracker; earns premium/fees but bears ITM risk.
  - trust level: untrusted
- Liquidator/forcer
  - Triggers liquidation/force-exercise/position closing for undercollateralized accounts; receives incentive/discount if configured.
  - trust level: untrusted
- Collateral depositor
  - Deposits/withdraws/redeems the underlying ERC20 into CollateralTracker; receives vault shares/claims used as margin.
  - trust level: untrusted
- Uniswap pool (V3) / PoolManager (V4)
  - Provides pricing, swap execution, and observation data; settlement anchor for intrinsic value and fee growth.
  - trust level: partially_trusted
- Oracle observer
  - Supplies TWAP/observations sourced from Uniswap or internal OraclePack logic; affects solvency and liquidation thresholds.
  - trust level: partially_trusted
- Guardian
  - Privileged emergency role: toggles safe mode/halts pathways, adjusts allowed parameters to protect solvency during oracle issues.
  - trust level: trusted
- Factory deployer/admin (Builder)
  - Coordinates deployment/configuration of pools and references (POOL_REFERENCE/COLLATERAL_REFERENCE), potentially setting template logic and admins.
  - trust level: trusted

## Trust Assumptions
- Uniswap V3/V4 core invariants hold (swap math, fee growth, observation ring buffer correctness).
- OraclePack derives price/vol/risk inputs from Uniswap observations with correct staleness, window, and manipulation resistance assumptions.
- Collateral tokens are ERC20-like; non-standard callbacks (ERC777), fee-on-transfer, rebasing, and tokens with hooks can break accounting unless explicitly handled.
- ERC1155Minimal implementation correctly enforces mint/burn authorization and does not allow supply/ownership spoofing affecting risk accounting.
- Guardian actions are honest and timely; safe mode can pause risk-increasing actions without enabling theft or selective liquidation.

## External Trust Boundaries
- Uniswap V3 Factory + Pools
  - Panoptic positions reference specific Uniswap pools; price, fees, and observations are settlement inputs. Pool callbacks and fee growth semantics affect premium/intrinsic accounting.
  - related components: PanopticFactoryV3, PanopticPool, PoolData, OraclePack, TokenId
- Uniswap V4 PoolManager
  - Hook/callback and lock/unlock patterns change reentrancy and settlement ordering assumptions versus V3.
  - related components: PanopticFactoryV4, PanopticPool, PoolData, OraclePack
- ERC20 collateral tokens
  - Transfer semantics affect CollateralTracker share accounting and any fee/premia distribution. Tokens with hooks can reenter and/or distort balances.
  - related components: CollateralTracker, PanopticPool, ERC20Minimal
- Shared/Separate Position Manager (SFPM)
  - If Panoptic relies on an external position manager for Uniswap positions/fees, incorrect approvals, callbacks, or fee claims can leak value.
  - related components: PanopticFactoryV3, PanopticFactoryV4, PanopticPool

## Assets / Security Properties to Protect
- Fully-collateralized invariant (no bad debt)
  - At all times, the sum of a user’s collateral value (per CollateralTracker) must cover worst-case option exposure under configured risk/oracle assumptions; otherwise protocol becomes undercollateralized.
  - related components: PanopticPool, CollateralTracker, OraclePack, PoolData, TokenId
- Conservation across collateral vault balances and shares
  - CollateralTracker ERC20 balance changes must reconcile with minted/burned shares and any reserved/locked margin; prevents share inflation or balance extraction.
  - related components: CollateralTracker, ERC20Minimal
- Position supply ↔ obligations bijection
  - ERC1155 token supply for each TokenId must map 1:1 to the protocol’s recorded obligations (premium accrual, intrinsic exposure, margin requirement) with correct sign conventions for long/short legs.
  - related components: PanopticPool, ERC1155Minimal, TokenId
- Oracle observation coherence and anti-manipulation windowing
  - All solvency checks and liquidation/exercise triggers must use consistent price inputs (spot vs TWAP) with explicit staleness bounds; mismatches enable griefing or theft via MEV manipulation.
  - related components: OraclePack, PoolData, PanopticPool
- Atomic settlement with Uniswap callbacks
  - Any path that moves tokens (swaps, fee collection, exercise) must leave the protocol fully paid by end of tx; callback-based settlement must be non-reentrant and exact.
  - related components: PanopticPool, PoolData, PanopticFactoryV3, PanopticFactoryV4
- Emergency controls are non-extractive
  - Guardian safe-mode/pauses must not allow selective value extraction, censorship leading to forced liquidations, or bypass of collateral withdrawal rules.
  - related components: PanopticGuardian, PanopticPool, CollateralTracker

## Top Review Themes
- CollateralTracker share accounting, locked margin, and non-standard token behavior
  - priority: critical
  - Collateral vault math is the accounting backbone. Any balance/share mismatch, rounding, or callback/reentrancy (ERC777) can steal collateral or fees (noted by prior Panoptic findings).
  - related components: CollateralTracker, PanopticPool, ERC20Minimal
  - related anchors: Conservation across collateral vault balances and shares
- Option position semantics (TokenId encoding) + ERC1155 mint/burn correctness
  - priority: critical
  - Most catastrophic losses come from misinterpreting legs (call/put, long/short, strike/range, ratio) or allowing mint/burn that desyncs obligations from tokens. Focus on sign, scaling, and multi-leg aggregation.
  - related components: TokenId, PanopticPool, ERC1155Minimal
  - related anchors: Position supply ↔ obligations bijection, Fully-collateralized invariant (no bad debt)
- Liquidation / force-exercise edge cases and griefing resistance
  - priority: high
  - Liquidation is the protocol’s backstop. Off-by-one ticks, rounding, partial close, and incentive calculation errors can create bad debt or allow DoS/lock of other users (historical removedLiquidity underflow / DoS class).
  - related components: PanopticPool, CollateralTracker, OraclePack
  - related anchors: Fully-collateralized invariant (no bad debt), Liquidation value monotonicity
- OraclePack / observation windowing and safe-mode transitions
  - priority: high
  - Perps-style options require robust TWAP/observation handling. Incorrect window selection, stale observations, or inconsistent spot/TWAP use across open/close/liquidate creates solvency bypass or unfair liquidation. Safe-mode must switch coherently.
  - related components: OraclePack, PoolData, PanopticGuardian, PanopticPool
  - related anchors: Oracle observation coherence and anti-manipulation windowing, Fully-collateralized invariant (no bad debt)
- Settlement and fee/premium attribution via Uniswap interactions (V3/V4 differences)
  - priority: high
  - Intrinsic/premium/fee flows depend on Uniswap feeGrowth and callback settlement. Ordering mistakes, reentrancy, or incorrect fee attribution can leak value or allow fee theft (historical ERC777 fee theft issue).
  - related components: PanopticPool, PoolData, PanopticFactoryV3, PanopticFactoryV4
  - related anchors: Atomic settlement with Uniswap callbacks, Premium/fee conservation

## Economic Primitives
- Collateral vault shares
  - kind: user_claim
  - User claim on underlying collateral token held by CollateralTracker; may be partially locked/encumbered as margin for short options.
  - related components: CollateralTracker, PanopticPool
- Encumbered (locked) margin / reserved collateral
  - kind: risk_state
  - Portion of a user’s collateral that is unavailable for withdrawal because it backs current short exposure; derived from risk engine + oracle inputs.
  - related components: PanopticPool, CollateralTracker, OraclePack
- ERC1155 option positions (TokenId)
  - kind: position_state
  - Tokenized multi-leg option contracts (long/short) referencing a Uniswap pool, tick ranges/strikes, ratios; mint/burn changes exposure.
  - related components: ERC1155Minimal, TokenId, PanopticPool
- Premium / fee accrual state
  - kind: fee_state
  - Accounting of premiums owed/earned and Uniswap fee growth attributable to option positions/managed liquidity; must be conserved and non-stealable.
  - related components: PanopticPool, PoolData, OraclePack
- Oracle observation pack (TWAP/spot)
  - kind: oracle_state
  - Packed observation data (ticks, timestamps, cumulative values) used for mark price, manipulation resistance, and risk checks.
  - related components: OraclePack, PoolData
- Uniswap pool-linked liquidity/position backing (SFPM-managed)
  - kind: pool_state
  - Underlying Uniswap liquidity/positions that Panoptic opens/manages to replicate option payoff and earn fees; includes owed tokens during callbacks.
  - related components: PanopticPool, PanopticFactoryV3, PanopticFactoryV4, PoolData
- Protocol safety mode / guardian flags
  - kind: control_state
  - Emergency configuration affecting whether new risk can be opened, which oracle sources are used, and how liquidation/closing behaves.
  - related components: PanopticGuardian, PanopticPool

## Critical State Transitions
- Deploy/register PanopticPool for a Uniswap pool
  - category: market_bootstrap
  - Factory instantiates a PanopticPool and associated CollateralTracker(s), wires references (SFPM, pool manager), and initializes immutable parameters.
  - entrypoints: PanopticFactoryV3, PanopticFactoryV4, Builder
  - affected primitives: Uniswap pool-linked liquidity/position backing (SFPM-managed), Protocol safety mode / guardian flags
- Deposit collateral (mint vault shares)
  - category: capital_entry
  - User transfers ERC20 collateral into CollateralTracker and receives shares/credits usable as margin.
  - entrypoints: CollateralTracker, PanopticPool
  - affected primitives: Collateral vault shares, Encumbered (locked) margin / reserved collateral
- Withdraw collateral (burn shares)
  - category: capital_exit
  - User burns shares and receives underlying collateral, subject to remaining locked margin after risk check.
  - entrypoints: CollateralTracker, PanopticPool
  - affected primitives: Collateral vault shares, Encumbered (locked) margin / reserved collateral
- Mint option position (open/increase exposure)
  - category: position_lifecycle
  - User mints ERC1155 TokenId(s) representing option legs; updates exposure, premium tracking, and increases required margin for shorts; may interact with Uniswap/SFPM.
  - entrypoints: PanopticPool
  - affected primitives: ERC1155 option positions (TokenId), Encumbered (locked) margin / reserved collateral, Premium / fee accrual state, Uniswap pool-linked liquidity/position backing (SFPM-managed)
- Burn option position (close/decrease exposure)
  - category: position_lifecycle
  - User burns ERC1155 position tokens; realizes PnL/premia, releases margin, and settles with Uniswap/SFPM as needed.
  - entrypoints: PanopticPool
  - affected primitives: ERC1155 option positions (TokenId), Encumbered (locked) margin / reserved collateral, Premium / fee accrual state, Uniswap pool-linked liquidity/position backing (SFPM-managed)
- Liquidate / force-close undercollateralized account
  - category: risk_settlement
  - Third party closes positions and seizes collateral (or triggers forced exercise) when margin insufficient under oracle; must reduce system risk and avoid creating bad debt.
  - entrypoints: PanopticPool
  - affected primitives: Encumbered (locked) margin / reserved collateral, ERC1155 option positions (TokenId), Collateral vault shares, Premium / fee accrual state
- Oracle update / observation sync
  - category: oracle_update
  - Refreshes OraclePack data from Uniswap observations; may be implicit in other actions; affects solvency and liquidation thresholds.
  - entrypoints: PanopticPool, OraclePack
  - affected primitives: Oracle observation pack (TWAP/spot), Encumbered (locked) margin / reserved collateral
- Guardian safe-mode toggle / parameter update
  - category: privileged_control
  - Guardian activates safety mode or adjusts guardrails (pauses minting, changes oracle windows, disables risky actions).
  - entrypoints: PanopticGuardian, PanopticPool
  - affected primitives: Protocol safety mode / guardian flags, Oracle observation pack (TWAP/spot), Encumbered (locked) margin / reserved collateral

## Accounting Anchors
- After any Uniswap callback-based operation, all owed token deltas must be settled by end-of-tx; protocol must not be left with unpaid obligations or dangling approvals.
  - why it matters: Callback/order bugs enable theft or protocol insolvency, especially with reentrancy-capable tokens or V4 lock patterns.
  - priority: critical
  - related components: PanopticPool, PanopticFactoryV3, PanopticFactoryV4, PoolData
- For each collateral token: underlying ERC20 balance held by CollateralTracker (plus/minus any explicitly tracked unpaid/owed amounts) must equal total shares * sharePrice (within rounding), and user share balances must sum to total share supply.
  - why it matters: Prevents share inflation, hidden insolvency, and extraction via rounding/reentrancy/fee-on-transfer tokens.
  - priority: critical
  - related components: CollateralTracker, ERC20Minimal
- A successful liquidation/force-close must not increase the liquidated account’s net short exposure or reduce total system collateralization; seized collateral value ≥ debt/exposure relieved (within configured incentive/discount).
  - why it matters: Ensures liquidations cannot be abused to create bad debt or drain collateral via incentive miscalc/rounding.
  - priority: critical
  - related components: PanopticPool, CollateralTracker, OraclePack
- For any account and token, locked/encumbered collateral must never underflow; it must be ≤ that account’s collateral and must monotonically decrease when exposure decreases (burn/liq).
  - why it matters: Underflow/negative locks can brick withdrawals or allow withdrawing encumbered collateral, creating bad debt.
  - priority: critical
  - related components: PanopticPool, CollateralTracker
- For each TokenId, total ERC1155 supply and per-user balances must match internal exposure representation used for margin, liquidation, and premium calculations (including long/short sign and ratios).
  - why it matters: A mismatch allows minting “free” claims, mispricing liquidation, or evading margin while retaining payoff.
  - priority: critical
  - related components: PanopticPool, ERC1155Minimal, TokenId
- All risk-critical computations within a single state transition must use a single coherent oracle snapshot (tick/time) with explicit staleness bounds; switching sources mid-call is forbidden.
  - why it matters: Prevents MEV manipulation where attacker opens/closes/liquidates using different prices within one transaction or across windows.
  - priority: high
  - related components: OraclePack, PoolData, PanopticPool
- Across mint/burn/liquidate/collect: premiums and fees paid by one side must equal premiums/fees received by the counterparty plus any explicit protocol cut; no path may create fees from nothing or allow double-collection.
  - why it matters: Fee theft/double counting directly transfers value; common in protocols integrating Uniswap feeGrowth and external token transfers.
  - priority: high
  - related components: PanopticPool, PoolData, OraclePack

## Main Review Surfaces
- TokenId encoding/decoding and leg aggregation math
- ERC1155Minimal mint/burn authorization and supply correctness
- CollateralTracker share math (deposit/withdraw), rounding, and locked margin updates
- PanopticPool position lifecycle: mint/burn, premium accounting, exposure updates
- Liquidation/force-close and incentive calculations
- OraclePack observation selection (TWAP/spot), staleness, and safe-mode gating

## Main Threat Surfaces
- Collateral share inflation / reentrancy via exotic tokens
  - priority: critical
  - mechanism: CollateralTracker deposits/withdrawals rely on ERC20 transfer semantics.
  - failure mode: ERC777 hooks or fee-on-transfer/rebasing causes shares minted without full collateral, or allows reentrant calls that manipulate locked margin/premium claims; can steal fees (historical).
  - affected components: CollateralTracker, PanopticPool
- TokenId misinterpretation / malformed legs
  - priority: critical
  - mechanism: Option legs encoded in TokenId drive exposure, margin, and settlement.
  - failure mode: Attacker crafts TokenId that passes validation but yields negative/overflowing amounts, inverted long/short sign, or tick-range edge cases causing free minting or undercollateralized shorts.
  - affected components: TokenId, PanopticPool, ERC1155Minimal
- Uniswap V3/V4 callback settlement + reentrancy/order dependence
  - priority: critical
  - mechanism: Operations involving Uniswap require paying token deltas in callbacks; V4 introduces lock/unlock sequencing.
  - failure mode: Callback reentrancy manipulates Panoptic state mid-settlement; approvals left open; partial settlement leaves protocol with unpaid deltas; edge-case revert leaves accounting mutated.
  - affected components: PanopticPool, PanopticFactoryV3, PanopticFactoryV4, PoolData
- Fee/premium double-collection or misattribution
  - priority: high
  - mechanism: Premium and Uniswap fee growth attributed to positions over time and realized on burn/liquidate/collect.
  - failure mode: Same fee growth consumed multiple times, fees claimable without owning exposure, or rounding drives systematic leakage; can drain shared fee pot.
  - affected components: PanopticPool, PoolData
- Locked margin underflow/DoS / withdrawal lock
  - priority: high
  - mechanism: Locked collateral updates occur on position changes and potentially per-leg accounting.
  - failure mode: Underflow or incorrect decrement locks other users or bricks withdrawals; can be exploited for griefing or to trap funds (historical class).
  - affected components: PanopticPool, CollateralTracker
- Oracle window manipulation / inconsistent snapshots
  - priority: high
  - mechanism: OraclePack uses Uniswap observations for TWAP/spot pricing used in solvency and liquidation.
  - failure mode: Attacker manipulates tick/observations or exploits stale windows to open positions underpriced, avoid liquidation, or liquidate others unfairly; inconsistent oracle reads within a tx create sandwichable paths.
  - affected components: OraclePack, PoolData, PanopticPool

## High-Value Review Questions
- At the end of mint/burn/liquidate, can you mechanically reconcile: (user collateral shares, locked margin) + (net position exposure) implies solvency under the same oracle snapshot? Where is the single ‘risk check’ enforced and can any path bypass it (including internal calls)?
  - priority: critical
  - related components: PanopticPool, CollateralTracker, OraclePack
  - related anchors: Locked margin is non-negative and upper-bounded, Oracle coherence (spot/TWAP/staleness), Fully-collateralized invariant (no bad debt)
- For each entrypoint that mints/burns ERC1155 positions: what is the exact mapping from TokenId (legs) → signed exposure vector, and is it impossible to craft a TokenId that causes (a) overflow/underflow, (b) sign flip, (c) zero-cost mint of positive payoff?
  - priority: critical
  - related components: TokenId, PanopticPool, ERC1155Minimal
  - related anchors: Position token supply ↔ exposure accounting bijection
- For each Uniswap interaction (V3 callback / V4 lock): are protocol state updates ordered as checks-effects-interactions, and is reentrancy prevented across both PanopticPool and CollateralTracker? Identify any external call before updating exposure/locks.
  - priority: critical
  - related components: PanopticPool, PanopticFactoryV3, PanopticFactoryV4, CollateralTracker
  - related anchors: Atomic callback settlement (Uniswap V3/V4)
- Liquidation/force-close: prove liquidation value monotonicity under rounding—does the liquidator ever receive more collateral value than exposure relieved beyond configured incentive? What happens at tick boundaries (at/just-in/out-of-range) and for multi-leg positions?
  - priority: critical
  - related components: PanopticPool, CollateralTracker, TokenId, OraclePack
  - related anchors: Liquidation value monotonicity (system risk decreases)
- Can any user action cause locked margin accounting to underflow or to be charged to the wrong account/token (e.g., cross-token confusion between token0/token1 trackers)? Specifically review any ‘removedLiquidity’/decrement style variables for unchecked subtraction.
  - priority: high
  - related components: PanopticPool, CollateralTracker, PoolData
  - related anchors: Locked margin is non-negative and upper-bounded
- Do CollateralTracker deposit/withdraw functions remain correct under: fee-on-transfer, rebasing, ERC777 hooks, tokens that revert on zero transfer, and tokens that change balance without transfer? If not supported, where is it explicitly prevented (allowlist/denylist) and tested?
  - priority: high
  - related components: CollateralTracker, PanopticPool
  - related anchors: CollateralTracker balance ↔ share supply conservation
- OraclePack: what are the exact observation windows and staleness constraints for (a) opening risk, (b) closing risk, (c) liquidation? Can an attacker cause different windows to be used in the same transaction (e.g., via nested calls) or force fallback to spot?
  - priority: high
  - related components: OraclePack, PanopticPool, PanopticGuardian
  - related anchors: Oracle coherence (spot/TWAP/staleness)
- When settling premiums/fees, what prevents double-claim across multiple burns/partial closes or via reentrancy? Is fee growth consumed with a per-position checkpoint and updated before external calls?
  - priority: high
  - related components: PanopticPool, PoolData
  - related anchors: Premium/fee conservation across settlement paths, Atomic callback settlement (Uniswap V3/V4)

## Repo Context
- analyzer: evm
- source repo shape: foundry
- preferred audit workspace shape: foundry
- runtime: evm
- language: solidity
- frameworks: foundry
- primary docs:
  - panoptic-v2-core/README.md
- primary code surfaces:
  - panoptic-v2-core/contracts/PanopticFactoryV3.sol
  - panoptic-v2-core/contracts/PanopticFactoryV4.sol
  - panoptic-v2-core/contracts/PanopticPool.sol
  - panoptic-v2-core/contracts/base/FactoryNFT.sol
  - panoptic-v2-core/contracts/tokens/ERC1155Minimal.sol
  - panoptic-v2-core/contracts/tokens/ERC20Minimal.sol
  - panoptic-v2-core/contracts/types/OraclePack.sol
  - panoptic-v2-core/contracts/types/PoolData.sol
  - panoptic-v2-core/contracts/types/TokenId.sol
  - panoptic-v2-core/contracts/Builder.sol
