# Threat Model

## Protocol Summary
Panoptic (v2 core) is a noncustodial, permissionless perpetual options protocol built on top of Uniswap V3/V4 pools. Users create option positions as tokenized contracts (ERC-1155) referencing a specific Uniswap pool and option “legs” encoded in a TokenId. LP-style collateral is deposited into CollateralTracker vaults per underlying token; option writers are required to post collateral and remain solvent against mark/ITM exposure derived from Uniswap price/oracle observations. Premiums/fees and intrinsic value are settled continuously/instantaneously via interactions with Uniswap (and a shared/separate SFPM/position manager). A Guardian role can trigger safety modes / halt certain actions, influencing oracle usage and risk parameters.

Panoptic should not be modeled as a vanilla option protocol with a simple terminal payoff. It is a composite system combining:
- Uniswap v3/v4 liquidity geometry
- tokenized multi-leg positions
- premium accounting
- collateral / lending-style accounting
- solvency, liquidation, and force-exercise state transitions

Core economic mechanism: mint/burn multi-leg option positions whose payoff and collateral requirement depend on Uniswap-linked price state, time/observation windows, and per-leg semantics; enforce solvency through a risk engine plus liquidation / force-exercise; account for collateral shares, premium snapshots, and settlement flows with strict conservation across ERC20 vault balances, ERC1155 position supply, and Uniswap fee/intrinsic settlement.

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
- RiskEngine implementations correctly translate TokenId legs, moneyness/range state, and utilization into collateral requirements and liquidation/exercise costs.
- Collateral tokens are ERC20-like; non-standard callbacks (ERC777), fee-on-transfer, rebasing, and tokens with hooks can break accounting unless explicitly handled.
- ERC1155Minimal implementation correctly enforces mint/burn authorization and does not allow supply/ownership spoofing affecting risk accounting.
- Guardian actions are honest and timely; safe mode can pause risk-increasing actions without enabling theft or selective extraction.

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
  - related components: PanopticPool, RiskEngine, CollateralTracker, OraclePack, PoolData, TokenId
- Conservation across collateral vault balances and shares
  - CollateralTracker ERC20 balance changes must reconcile with minted/burned shares and any reserved/locked margin; prevents share inflation or balance extraction.
  - related components: CollateralTracker, ERC20Minimal
- Position supply ↔ obligations bijection
  - ERC1155 token supply for each TokenId must map 1:1 to the protocol’s recorded obligations (premium accrual, intrinsic exposure, margin requirement) with correct sign conventions for long/short legs.
  - related components: PanopticPool, RiskEngine, ERC1155Minimal, TokenId
- Oracle observation coherence and anti-manipulation windowing
  - All solvency checks and liquidation/exercise triggers must use consistent price inputs (spot vs TWAP) with explicit staleness bounds; mismatches enable griefing or theft via MEV manipulation.
  - related components: OraclePack, PoolData, PanopticPool, RiskEngine
- Atomic settlement with Uniswap callbacks
  - Any path that moves tokens (swaps, fee collection, exercise) must leave the protocol fully paid by end of tx; callback-based settlement must be non-reentrant and exact.
  - related components: PanopticPool, PoolData, PanopticFactoryV3, PanopticFactoryV4
- Premium checkpoint integrity
  - Premium accumulator snapshots, settlement state, and per-position checkpoints must remain synchronized across mint/burn/liquidate/settle; no newly added liquidity may inherit old premia, and no partial exit may leave stale claimable premia behind.
  - related components: PanopticPool, PoolData, RiskEngine, TokenId
- Emergency controls are non-extractive and non-distortive
  - Guardian safe-mode/pauses must not allow selective value extraction, denial of risk-reducing exits, censorship leading to forced liquidations, or incoherent oracle/risk transitions.
  - related components: PanopticGuardian, PanopticPool, RiskEngine, CollateralTracker

## Top Review Themes
- CollateralTracker share accounting, locked margin, and non-standard token behavior
  - priority: critical
  - Collateral vault math is the accounting backbone. Any balance/share mismatch, rounding, or callback/reentrancy (ERC777) can steal collateral or fees.
  - related components: CollateralTracker, PanopticPool, ERC20Minimal
  - related anchors: Conservation across collateral vault balances and shares
- RiskEngine solvency and margin math
  - priority: critical
  - RiskEngine defines when an account is solvent, how long/short legs consume buying power, how liquidation bonus is computed, and how bad debt/haircuts propagate. This is the core financial logic surface.
  - related components: RiskEngine, PanopticPool, TokenId, OraclePack
  - related anchors: Fully-collateralized invariant (no bad debt), Oracle observation coherence and anti-manipulation windowing
- Option position semantics (TokenId encoding) + ERC1155 mint/burn correctness
  - priority: critical
  - Most catastrophic losses come from misinterpreting legs (call/put, long/short, strike/range, ratio) or allowing mint/burn that desyncs obligations from tokens. Focus on sign, scaling, and multi-leg aggregation.
  - related components: TokenId, PanopticPool, RiskEngine, ERC1155Minimal
  - related anchors: Position supply ↔ obligations bijection, Fully-collateralized invariant (no bad debt)
- Premium accumulator / checkpoint consistency
  - priority: critical
  - Premium accounting is not just about conservation; it also depends on correct checkpointing across lifecycle transitions. Minted positions must not inherit historical premium, and exiting positions must not leave stale claims or distort remaining liquidity baselines.
  - related components: PanopticPool, PoolData, TokenId
  - related anchors: Premium checkpoint integrity
- Liquidation / force-exercise edge cases and griefing resistance
  - priority: high
  - Liquidation is the protocol’s backstop. Off-by-one ticks, rounding, partial close, exercise cost mismatch, and incentive errors can create bad debt or allow DoS/lock of other users.
  - related components: PanopticPool, RiskEngine, CollateralTracker, OraclePack
  - related anchors: Fully-collateralized invariant (no bad debt)
- Structural exercisable vs economic exercisable
  - priority: high
  - If an exercise path is gated only by structural leg properties rather than true economic moneyness, the real protection must come from exercise cost and settlement math. Review whether force exercise can be used as an unfair close/griefing path.
  - related components: PanopticPool, RiskEngine, TokenId
  - related anchors: Fully-collateralized invariant (no bad debt), Premium checkpoint integrity
- OraclePack / observation windowing and safe-mode transitions
  - priority: high
  - Perps-style options require robust TWAP/observation handling. Incorrect window selection, stale observations, or inconsistent spot/TWAP use across open/close/liquidate creates solvency bypass or unfair liquidation. Safe-mode must switch coherently.
  - related components: OraclePack, PoolData, PanopticGuardian, PanopticPool, RiskEngine
  - related anchors: Oracle observation coherence and anti-manipulation windowing
- Settlement and fee/premium attribution via Uniswap interactions (V3/V4 differences)
  - priority: high
  - Intrinsic/premium/fee flows depend on Uniswap feeGrowth and callback settlement. Ordering mistakes, reentrancy, or incorrect fee attribution can leak value or allow fee theft.
  - related components: PanopticPool, PoolData, PanopticFactoryV3, PanopticFactoryV4
  - related anchors: Atomic settlement with Uniswap callbacks, Premium checkpoint integrity

## Economic Primitives
- Collateral vault shares
  - kind: user_claim
  - User claim on underlying collateral token held by CollateralTracker; may be partially locked/encumbered as margin for short options.
  - related components: CollateralTracker, PanopticPool
- Encumbered (locked) margin / reserved collateral
  - kind: risk_state
  - Portion of a user’s collateral that is unavailable for withdrawal because it backs current short exposure; derived from RiskEngine + oracle inputs.
  - related components: PanopticPool, RiskEngine, CollateralTracker, OraclePack
- ERC1155 option positions (TokenId)
  - kind: position_state
  - Tokenized multi-leg option contracts (long/short) referencing a Uniswap pool, tick ranges/strikes, ratios; mint/burn changes exposure.
  - related components: ERC1155Minimal, TokenId, PanopticPool
- Premium / fee accrual state
  - kind: fee_state
  - Accounting of premiums owed/earned and Uniswap fee growth attributable to option positions/managed liquidity; must be conserved and non-stealable.
  - related components: PanopticPool, PoolData, OraclePack
- Premium checkpoints / settled premium pools
  - kind: accounting_state
  - Per-position and/or per-leg snapshots used to determine accrued premia since the last lifecycle event; must stay aligned with actual settled token availability.
  - related components: PanopticPool, PoolData, TokenId
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
  - related components: PanopticGuardian, PanopticPool, RiskEngine

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
  - affected primitives: ERC1155 option positions (TokenId), Encumbered (locked) margin / reserved collateral, Premium / fee accrual state, Premium checkpoints / settled premium pools, Uniswap pool-linked liquidity/position backing (SFPM-managed)
- Burn option position (close/decrease exposure)
  - category: position_lifecycle
  - User burns ERC1155 position tokens; realizes PnL/premia, releases margin, and settles with Uniswap/SFPM as needed.
  - entrypoints: PanopticPool
  - affected primitives: ERC1155 option positions (TokenId), Encumbered (locked) margin / reserved collateral, Premium / fee accrual state, Premium checkpoints / settled premium pools, Uniswap pool-linked liquidity/position backing (SFPM-managed)
- Settle premium without changing exposure
  - category: position_lifecycle
  - User or external actor updates premium settlement state for existing positions without changing token supply; should not change net exposure, only accounting realization.
  - entrypoints: PanopticPool
  - affected primitives: Premium / fee accrual state, Premium checkpoints / settled premium pools
- Liquidate / force-close undercollateralized account
  - category: risk_settlement
  - Third party closes positions and seizes collateral (or triggers forced exercise) when margin insufficient under oracle; must reduce system risk and avoid creating bad debt.
  - entrypoints: PanopticPool
  - affected primitives: Encumbered (locked) margin / reserved collateral, ERC1155 option positions (TokenId), Collateral vault shares, Premium / fee accrual state, Premium checkpoints / settled premium pools
- Oracle update / observation sync
  - category: oracle_update
  - Refreshes OraclePack data from Uniswap observations; may be implicit in other actions; affects solvency and liquidation thresholds.
  - entrypoints: PanopticPool, OraclePack
  - affected primitives: Oracle observation pack (TWAP/spot), Encumbered (locked) margin / reserved collateral
- Guardian safe-mode toggle / parameter update
  - category: privileged_control
  - Guardian activates safety mode or adjusts guardrails (pauses minting, changes oracle windows, disables risky actions).
  - entrypoints: PanopticGuardian, PanopticPool, RiskEngine
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
  - related components: PanopticPool, RiskEngine, CollateralTracker, OraclePack
- For any account and token, locked/encumbered collateral must never underflow; it must be ≤ that account’s collateral and must monotonically decrease when exposure decreases (burn/liq).
  - why it matters: Underflow/negative locks can brick withdrawals or allow withdrawing encumbered collateral, creating bad debt.
  - priority: critical
  - related components: PanopticPool, RiskEngine, CollateralTracker
- For each TokenId, total ERC1155 supply and per-user balances must match internal exposure representation used for margin, liquidation, and premium calculations (including long/short sign and ratios).
  - why it matters: A mismatch allows minting “free” claims, mispricing liquidation, or evading margin while retaining payoff.
  - priority: critical
  - related components: PanopticPool, RiskEngine, ERC1155Minimal, TokenId
- All risk-critical computations within a single state transition must use a single coherent oracle snapshot (tick/time) with explicit staleness bounds; switching sources mid-call is forbidden.
  - why it matters: Prevents MEV manipulation where attacker opens/closes/liquidates using different prices within one transaction or across windows.
  - priority: high
  - related components: OraclePack, PoolData, PanopticPool, RiskEngine
- Across mint/burn/liquidate/collect: premiums and fees paid by one side must equal premiums/fees received by the counterparty plus any explicit protocol cut; no path may create fees from nothing or allow double-collection.
  - why it matters: Fee theft/double counting directly transfers value; common in protocols integrating Uniswap feeGrowth and external token transfers.
  - priority: high
  - related components: PanopticPool, PoolData, OraclePack
- For each position lifecycle transition, premium accumulator snapshots and settlement baselines must be updated exactly once and in the correct direction; newly minted short liquidity must not inherit old premium, and remaining liquidity after burn must preserve only its legitimate historical basis.
  - why it matters: This is where “conserved in aggregate but wrong per user/per leg” bugs often appear, especially under partial close and multi-leg tokenIds.
  - priority: high
  - related components: PanopticPool, PoolData, TokenId
- Any force exercise path must preserve economic consistency: if a structurally exercisable position is forcibly closed, the cost charged and value transferred must be bounded by the same oracle/risk assumptions used for solvency.
  - why it matters: Prevents a structurally valid but economically abusive force-close path.
  - priority: high
  - related components: PanopticPool, RiskEngine, OraclePack

## Main Review Surfaces
- TokenId encoding/decoding and leg aggregation math
- ERC1155Minimal mint/burn authorization and supply correctness
- CollateralTracker share math (deposit/withdraw), rounding, delegate/revoke behavior, and locked margin updates
- PanopticPool position lifecycle: dispatch/dispatchFrom, mint/burn, premium accounting, settlement, exposure updates
- RiskEngine: `isAccountSolvent`, `_getMargin`, `exerciseCost`, `getLiquidationBonus`, `haircutPremia`
- Liquidation/force-close and incentive calculations
- OraclePack observation selection (TWAP/spot), staleness, and safe-mode gating
- Uniswap callback / SFPM settlement ordering and reentrancy boundaries

## Main Threat Surfaces
- Collateral share inflation / reentrancy via exotic tokens
  - priority: critical
  - mechanism: CollateralTracker deposits/withdrawals rely on ERC20 transfer semantics.
  - failure mode: ERC777 hooks or fee-on-transfer/rebasing causes shares minted without full collateral, or allows reentrant calls that manipulate locked margin/premium claims.
  - affected components: CollateralTracker, PanopticPool
- TokenId misinterpretation / malformed legs
  - priority: critical
  - mechanism: Option legs encoded in TokenId drive exposure, margin, and settlement.
  - failure mode: Attacker crafts TokenId that passes validation but yields negative/overflowing amounts, inverted long/short sign, or tick-range edge cases causing free minting or undercollateralized shorts.
  - affected components: TokenId, PanopticPool, RiskEngine, ERC1155Minimal
- Uniswap V3/V4 callback settlement + reentrancy/order dependence
  - priority: critical
  - mechanism: Operations involving Uniswap require paying token deltas in callbacks; V4 introduces lock/unlock sequencing.
  - failure mode: Callback reentrancy manipulates Panoptic state mid-settlement; approvals left open; partial settlement leaves protocol with unpaid deltas; edge-case revert leaves accounting mutated.
  - affected components: PanopticPool, PanopticFactoryV3, PanopticFactoryV4, PoolData
- Fee/premium double-collection or misattribution
  - priority: high
  - mechanism: Premium and Uniswap fee growth attributed to positions over time and realized on burn/liquidate/collect.
  - failure mode: Same fee growth consumed multiple times, fees claimable without owning exposure, stale checkpoints leave residual claims, or rounding drives systematic leakage.
  - affected components: PanopticPool, PoolData, TokenId
- Locked margin underflow/DoS / withdrawal lock
  - priority: high
  - mechanism: Locked collateral updates occur on position changes and potentially per-leg accounting.
  - failure mode: Underflow or incorrect decrement locks other users or bricks withdrawals; can be exploited for griefing or to trap funds.
  - affected components: PanopticPool, RiskEngine, CollateralTracker
- Oracle window manipulation / inconsistent snapshots
  - priority: high
  - mechanism: OraclePack uses Uniswap observations for TWAP/spot pricing used in solvency and liquidation.
  - failure mode: Attacker manipulates tick/observations or exploits stale windows to open positions underpriced, avoid liquidation, or liquidate others unfairly; inconsistent oracle reads within a tx create sandwichable paths.
  - affected components: OraclePack, PoolData, PanopticPool, RiskEngine
- Structurally valid but economically abusive force exercise
  - priority: high
  - mechanism: Exercise gating may only check leg structure, while economic fairness is deferred to downstream cost/settlement logic.
  - failure mode: Attacker forces closure of positions in economically inappropriate states, creating griefing or unfair transfer.
  - affected components: PanopticPool, RiskEngine, TokenId
- Privileged denial / safe-mode distortion
  - priority: high
  - mechanism: Guardian can alter safe-mode/oracle behavior and action availability.
  - failure mode: Safe mode blocks risk-reducing exits, creates selective liquidation windows, or switches oracle/risk assumptions mid-regime in a way that disadvantages users.
  - affected components: PanopticGuardian, PanopticPool, RiskEngine, OraclePack

## High-Value Review Questions
- At the end of mint/burn/liquidate, can you mechanically reconcile: (user collateral shares, locked margin) + (net position exposure) implies solvency under the same oracle snapshot? Where is the single ‘risk check’ enforced and can any path bypass it?
  - priority: critical
  - related components: PanopticPool, RiskEngine, CollateralTracker, OraclePack
  - related anchors: Fully-collateralized invariant (no bad debt), Oracle observation coherence and anti-manipulation windowing
- For each entrypoint that mints/burns ERC1155 positions: what is the exact mapping from TokenId (legs) → signed exposure vector, and is it impossible to craft a TokenId that causes (a) overflow/underflow, (b) sign flip, (c) zero-cost mint of positive payoff?
  - priority: critical
  - related components: TokenId, PanopticPool, RiskEngine, ERC1155Minimal
  - related anchors: Position supply ↔ obligations bijection
- In `RiskEngine.isAccountSolvent`, what exact stress inputs are used, and are they consistent with `_getMargin`, `exerciseCost`, and liquidation bonus calculations? Does any state transition mix inconsistent risk formulas?
  - priority: critical
  - related components: RiskEngine, PanopticPool, OraclePack, TokenId
  - related anchors: Fully-collateralized invariant (no bad debt), Oracle observation coherence and anti-manipulation windowing
- For each Uniswap interaction (V3 callback / V4 lock): are protocol state updates ordered as checks-effects-interactions, and is reentrancy prevented across both PanopticPool and CollateralTracker? Identify any external call before updating exposure/locks/checkpoints.
  - priority: critical
  - related components: PanopticPool, PanopticFactoryV3, PanopticFactoryV4, CollateralTracker
  - related anchors: Atomic settlement with Uniswap callbacks
- Liquidation/force-close: prove liquidation value monotonicity under rounding—does the liquidator ever receive more collateral value than exposure relieved beyond configured incentive? What happens at tick boundaries and for multi-leg positions?
  - priority: critical
  - related components: PanopticPool, RiskEngine, CollateralTracker, TokenId, OraclePack
  - related anchors: A successful liquidation/force-close must not reduce system collateralization
- Can any user action cause locked margin accounting to underflow or to be charged to the wrong account/token? Specifically review any decrement-style variables, removed-liquidity paths, and cross-token tracker updates.
  - priority: high
  - related components: PanopticPool, RiskEngine, CollateralTracker, PoolData
  - related anchors: Locked/encumbered collateral must never underflow
- Do CollateralTracker deposit/withdraw functions remain correct under fee-on-transfer, rebasing, ERC777 hooks, tokens that revert on zero transfer, and tokens that change balance without transfer? If unsupported, where is it explicitly prevented and tested?
  - priority: high
  - related components: CollateralTracker, PanopticPool
  - related anchors: Conservation across collateral vault balances and shares
- For premium settlement, what prevents checkpoint inheritance, double-claim, or stale baseline reuse across mint/burn/partial close/forced close? Are checkpoints updated before all external calls?
  - priority: high
  - related components: PanopticPool, PoolData, TokenId
  - related anchors: Premium checkpoint integrity
- If `validateIsExercisable` is structural, what exact economic guardrail is imposed by `exerciseCost`? Can a position be force-exercised while economically OTM or otherwise not meaningfully exercisable under intuitive option semantics?
  - priority: high
  - related components: PanopticPool, RiskEngine, TokenId, OraclePack
  - related anchors: Any force exercise path must preserve economic consistency
- OraclePack: what are the exact observation windows and staleness constraints for (a) opening risk, (b) closing risk, (c) liquidation, and (d) safe mode? Can an attacker or guardian action cause different windows to be used in the same transaction or state transition?
  - priority: high
  - related components: OraclePack, PanopticPool, RiskEngine, PanopticGuardian
  - related anchors: Oracle observation coherence and anti-manipulation windowing
- Can Guardian safe mode block only risk-increasing actions, or can it also block risk-reducing burns, settlement, withdrawals, or premium collection? Does any privileged timing create selective liquidation opportunities?
  - priority: high
  - related components: PanopticGuardian, PanopticPool, RiskEngine, CollateralTracker
  - related anchors: Emergency controls are non-extractive and non-distortive

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
  - panoptic-v2-core/contracts/CollateralTracker.sol
  - panoptic-v2-core/contracts/RiskEngine.sol
  - panoptic-v2-core/contracts/base/FactoryNFT.sol
  - panoptic-v2-core/contracts/tokens/ERC1155Minimal.sol
  - panoptic-v2-core/contracts/tokens/ERC20Minimal.sol
  - panoptic-v2-core/contracts/types/OraclePack.sol
  - panoptic-v2-core/contracts/types/PoolData.sol
  - panoptic-v2-core/contracts/types/TokenId.sol
  - panoptic-v2-core/contracts/Builder.sol

## Suggested Review Order
1. PanopticPool main lifecycle
   - `dispatch`
   - `dispatchFrom`
   - `_mintOptions`
   - `_burnOptions`
   - premium settlement paths
2. RiskEngine core financial logic
   - `isAccountSolvent`
   - `_getMargin`
   - `exerciseCost`
   - `getLiquidationBonus`
   - `haircutPremia`
3. CollateralTracker accounting paths
   - deposit / withdraw / redeem
   - locked margin interactions
   - `delegate`
   - `revoke`
   - `getRefundAmounts`
4. OraclePack / PoolData
   - oracle snapshot coherence
   - staleness / TWAP window handling
   - safe-mode behavior
5. Uniswap callback / SFPM integration
   - settlement ordering
   - reentrancy boundaries
   - fee-growth attribution / collection paths
```
