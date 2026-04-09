# Threat Model

## Protocol Summary
Perennial V2 is a synthetic perpetuals system with lazily-settled market-wide and account-wide accounting.

Each market is a `Market` instance created by `MarketFactory`. A market is parameterized by:

- a settlement / collateral token
- an oracle provider

In the core contracts, positions are tracked in three buckets:

- `maker`
- `long`
- `short`

Makers provide passive liquidity inventory to the market's aggregate pricing and settlement model. Takers hold directional exposure through `long` and `short` buckets.

The accounting engine is split across:

- `Market.sol`
  - orchestration, state loading/storing, update / settle entrypoints, permission checks
- `VersionLib.sol`
  - global accumulation of fees, offsets, funding, interest, price PnL, and exposure across oracle versions
- `CheckpointLib.sol`
  - account-local realization of global accumulator deltas into concrete collateral changes

State is settled lazily:

- global settlement advances pending global orders into `Version` snapshots
- local settlement advances a specific account's pending orders into `Checkpoint` snapshots
- most user interactions implicitly settle first rather than relying on continuous background settlement

This makes sequencing and accumulator correctness the main accounting boundary of the system.

## Actors

### Protocol / User-Side Actors
- Factory owner / protocol owner
- Market coordinator
- Market creator
- Trader / taker
- Maker / LP
- Intent signer
- Fill solver / executor
- Operator / delegated account manager
- Referrer / originator / solver-referrer recipient
- Protected-order executor / designated liquidator-recipient
- Settlement caller

### External Dependencies
- Oracle provider
- Settlement / collateral token
- Shared `equilibria/root` math, accumulator, PID, and adiabatic libraries
- Verifier contract for EIP-712 signed messages

## Trust Assumptions
- The factory owner only enables safe market definitions, oracle providers, and protocol parameters.
- The market coordinator updates risk parameters responsibly and does not set economically dangerous values.
- The oracle returns correctly scaled, manipulation-resistant, and timely prices / versions.
- The settlement token behaves close enough to standard ERC20 semantics:
  - no fee-on-transfer behavior
  - no rebasing surprises that break accounting assumptions
  - no unexpected reentrancy on transfer / transferFrom
- The verifier correctly enforces signer authorization, nonce, expiry, domain, and signature validity.
- Solver / intent execution infrastructure does not systematically route fills unfairly or maliciously against users.
- The `equilibria/root` fixed-point and accumulator libraries are correct, especially around signedness, scaling, and zero / min / max handling.
- Markets are deployed with economically meaningful oracle/collateral pairings and sane fee curves.
- Protocol/product-level collateral restrictions are enforced at deployment / integration level where intended.

## External Trust Boundaries
- `oracle.at(timestamp)` / related oracle reads:
  - determine the price, validity, and timestamp boundary that drives settlement
- `Verifier.verifyIntent`
- `Verifier.verifyFill`
- `Verifier.verifyTake`
  - determine whether delegated / signed order flow is authentic
- ERC20 `push` / `pull` boundaries:
  - token movement is relied upon for collateral movement, claims, and exposure settlement

These are not passive integrations. They directly gate accounting-critical state transitions.

## Accounting Anchors

### Live State Anchors
- `Global`
  - latest/current order ids
  - fee buckets
  - `pAccumulator`
  - market-level `exposure`
- `Local`
  - latest/current order ids for one account
  - collateral / claimable balances
  - local protection / invalidation state

### Historical Settlement Anchors
- `Version`
  - market-wide cumulative accumulator snapshot at an oracle version / timestamp key
- `Checkpoint`
  - account-local settlement snapshot at a version / timestamp key

### Global Accounting Anchor: `VersionLib.accumulate`
`VersionLib` rolls the market from one oracle version to the next by carrying prior accumulators forward and then adding:

- settlement fee
- liquidation fee
- base maker/taker trade fee
- linear / proportional / adiabatic execution offsets
- adiabatic exposure PnL
- funding
- interest
- pure price PnL

Important formulas:

- Settlement fee per order:
  - `orders = order.orders - guarantee.orders`
  - `settlementFeeIndexDelta = - settlementFee / orders`
- Liquidation fee per protected unit:
  - `liquidationFee = settlementFee * riskParameter.liquidationFee`
- Base trade fees:
  - `makerFee = makerTotal * |price| * marketParameter.makerFee`
  - `takerFee = takerTotal * |price| * marketParameter.takerFee`
- Linear offset fee:
  - `linearFee = |change| * |price| * linearFeeRate`
- Proportional offset fee:
  - `proportionalFee = |change| * |price| * (|change| / scale) * proportionalFeeRate`
- Adiabatic trading fee:
  - `adiabaticFee = change * price * adiabaticRate * average(normalized skew across trade path)`
- Adiabatic exposure:
  - `exposure = (adiabaticRate * skew^2) / (2 * scale)`
  - `adiabaticExposure = (p1 - p0) * exposure`

### Local Accounting Anchor: `CheckpointLib.accumulate`
`CheckpointLib` turns global accumulator deltas into one account's realized amounts.

Conceptually:

- `collateralDelta = valueDelta + priceOverride - tradeFee - offset - settlementFee - liquidationFee`

Where:

- `valueDelta`
  - comes from applying `makerValue`, `longValue`, `shortValue` deltas to the account's prior position
- `priceOverride`
  - comes from guarantee price adjustment / execution override
- `tradeFee`
  - comes from maker/taker fee accumulators
- `offset`
  - comes from maker/taker offset accumulators
- `settlementFee`
  - comes from settlement-fee accumulator applied per order count
- `liquidationFee`
  - comes from protected/liquidation-fee accumulator

The main audit question here is whether every local realization exactly matches the account's intended share of the corresponding global accumulator delta.

## Main Review Surfaces

### Owner / Governance Surface
- `MarketFactory.create`
- factory-level protocol parameter updates
- market-level coordinator assignment
- market-level parameter updates
- market-level risk parameter updates

This surface can change market safety without directly moving user funds. The main review goal is whether privileged parameter changes can create:

- unfair value transfer
- broken settlement
- bad debt / insolvency
- liveness failure

### Market Creation Surface
- market identity and market definition correctness
- oracle / token compatibility
- initialization sequencing
- inherited instance / owner / pauser wiring

Even if creation is privileged, wrong market definition is still a major risk because market identity depends on the chosen dependencies.

### Settlement Surface
- `settle(account)`
- implicit settlement inside update flows
- ordering between global and local queue processing
- readiness gating for pending orders

Because settlement is lazy, this is one of the protocol's most important boundaries.

### Update Surface
- direct market updates
- signed `Take` updates
- direct `Intent` fills
- signed `Fill` updates
- absolute-position and delta-position overloads

All update paths eventually create pending `Order` objects, but the authentication, guarantee, fee, and sequencing assumptions differ by path.

### Intent / Guarantee / Solver Surface
- creation of `Guarantee`
- guarantee fee exclusion logic
- price override logic
- originator / solver / referrer fee attribution
- invalidation / protected-order handling

This is a distinct surface from normal market updates and should be reviewed separately.

Important semantics:

- `Guarantee.orders`
  - fee-exempt order count for settlement-fee logic
- `Guarantee.takerFee`
  - fee-exempt taker quantity for ordinary taker trade-fee logic

### Claim Surface
- `claimFee`
- `claimExposure`

These functions settle previously accumulated balances out of the market and therefore are sensitive to sign conventions and ownership assumptions.

## Main Economic Risk Questions
- Does `CheckpointLib` realize the exact account share of every global accumulator change with correct sign and denominator?
- Are maker/taker fee accumulators and maker/taker offset accumulators intentionally separate, or can users be double-charged across paths?
- Can guarantee-adjusted quantities cause incorrect fee exclusion, price override, or settlement-fee counting?
- Can protected / invalidatable orders be charged liquidation fee too often or against the wrong quantity after aggregation?
- Does lazy settlement create path dependence between otherwise similar user actions?
- Can pending-order aggregation or cross-version sequencing cause global/local mismatch?
- Are accumulator denominators always the intended units:
  - position size
  - order count
  - protected unit count
- Are maker-value credits and taker-offset debits always sign-consistent for linear / proportional / adiabatic fee flows?
- Can adiabatic exposure create hidden market-level value leakage through `Global.exposure` or `claimExposure()`?
- Can funding direction, funding fee spread, and maker-receive-only mode flip signs in unintended ways?
- Does interest accrue on the intended utilized notional and get split across maker / long / short exactly once?
- Does socialization correctly limit taker realizations when maker backing is insufficient?
- Are the extra skew-state economics:
  - adiabatic fee
  - adiabatic exposure
  - funding-state effects
  intentional, internally consistent, and clearly disclosed?
- Are the total trader-facing economics explainable as one coherent settlement result rather than a collection of loosely-related fee and PnL components?
- Is skew-induced wealth transfer consistent with the intended maker/taker design, especially when makers are treated as passive aggregate liquidity and takers face both offset costs and later skew-state realizations?
- Might users or integrators misunderstand:
  - position PnL
  - full settlement result
  and therefore misprice positions, collateral needs, or execution quality?
- Can stale / invalid oracle versions leave users with wrong pending state, wrong guarantee behavior, or wrong version snapshots?
- Can parameter updates mid-market unfairly reprice existing risk or leak value through `Global.update(...)` reconciliation?
- Can intent / fill authorization, domain binding, and nonce handling be replayed or bypassed across markets?
- Can exposure and claimable fee settlement transfer value to owner / referrer / solver unexpectedly under edge-case signs or zero-liquidity states?

## Unit / Denominator Checks
- Settlement fee uses order count.
- Liquidation fee uses protected-unit count of `1`.
- Base trade fees use maker/taker traded magnitude.
- Offsets use side-specific maker/taker traded magnitude.
- Funding uses socialized taker notional.
- Interest uses utilized notional.
- Ordinary price PnL uses socialized taker size.
- Adiabatic exposure uses skew-derived exposure rather than direct traded size.

## Code-Specific Risk Themes From `Market.sol`, `VersionLib.sol`, and `CheckpointLib.sol`
- `Market.sol` is not merely routing; it is the protocol's sequencing layer. Incorrect ordering between:
  - load
  - settle
  - create order / guarantee
  - process refs
  - store
  can break otherwise-correct library math.
- `VersionLib.sol` uses cumulative accumulators heavily. Most review work is not “is this fee formula plausible,” but “is the right signed per-unit index written with the right denominator at the right step?”
- `CheckpointLib.sol` is the main fairness boundary for users. Any mismatch between global accumulator semantics and local realization semantics creates direct user value transfer.
- `Guarantee` is not just “fee-free quantity.” It is a sidecar accounting object for guaranteed execution, price adjustment, solver/originator attribution, and selective fee treatment.
- `Guarantee.orders` and `Guarantee.takerFee` are exemption quantities for different fee domains:
  - settlement-fee order count
  - ordinary taker-fee quantity
- The protocol mixes:
  - direct fee accumulators
  - offset accumulators
  - maker/long/short value accumulators
  - global exposure buckets
  Review should treat these as distinct accounting domains rather than one blended PnL stream.
- Liquidation fee is a protected-order / liquidator-compensation path. Its presence in checkpoint settlement does not by itself prove that a user was liquidated in the intuitive UI sense.
- `claimExposure()` settles a market-level residual bucket between market and owner. This deserves separate sign and fairness review from normal user collateral settlement.
- `pAccumulator` and `pController` make funding stateful across time; funding is not a stateless function of current skew alone.
- Socialization functions in `Position.sol` are core accounting logic, not merely helper math:
  - `longSocialized`
  - `shortSocialized`
  - `takerSocialized`
  - `socializedMakerPortion`
- Adiabatic exposure should be understood as skew-state price sensitivity:
  - it is realized into maker value if makers exist
  - otherwise it is realized into `Global.exposure`
  It should not be described as a separate long-side or short-side value accumulator.
- Direct market updates trade against aggregate market liquidity, but intent/fill updates pair explicit account legs. Review should not assume those flows have identical trust and fairness properties.
- User-visible “PnL” can differ materially from naive directional price PnL because full settlement also includes:
  - funding
  - interest
  - offsets
  - price override
  - settlement fee
  - liquidation/protection fee
  - skew-state economics
  This is a product/comprehension risk even when the code is correct.

### User-Facing Economic Interpretation Risk
A user's realized collateral delta is not equivalent to naive directional PnL. It is the net result of:

- global accumulator realization
- guarantee price adjustment
- minus explicit fees
- minus execution offsets

This creates a real product/fairness review surface even when accounting is internally consistent.

## Initial Review Priorities
- Validate the global-to-local accounting handshake:
  - `VersionLib` writes
  - `CheckpointLib` realizes
- Review settlement sequencing around:
  - `global.currentId / latestId`
  - `local.currentId / latestId`
  - readiness checks
  - stale / invalid oracle versions
- Review guarantee-adjusted fee logic:
  - settlement fee
  - taker fee
  - price override
  - solver / originator fees
- Review funding sign logic, especially:
  - PID controller rate
  - fee spread
  - maker-receive-only
  - minor-side redirection to makers
- Review interest notional, utilization, and maker/taker split under:
  - balanced markets
  - heavily imbalanced markets
  - socialized states
  - zero-maker / zero-taker edge cases
- Review adiabatic fee and adiabatic exposure together; they are economically linked but accounted in different places.
- Review owner/coordinator parameter updates as value-transfer surfaces, not only access-control surfaces.
- Review `claimFee` and `claimExposure` as final settlement egress paths for non-user balances.
