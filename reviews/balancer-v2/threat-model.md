# Balancer V2 Threat Model

## 1. Protocol Summary

Balancer V2 is a generalized AMM system built around a shared **Vault + pool-specific math + factories + pool families** architecture.

The Vault is the central accounting and settlement layer. It custody-holds ERC20 tokens, tracks per-pool token balances, separates **cash** balances from **managed** balances, executes swaps and batch swaps, handles joins and exits, supports flash loans, maintains internal balances, and interacts with pool contracts through callback-style interfaces.

Pools define the economic logic. Different pool families implement different pricing and accounting models:

- Weighted Pools
- Stable Pools
- Composable Stable Pools
- Managed Pools
- Liquidity Bootstrapping Pools
- Linear / Boosted Pools, if included in scope

Factories deploy pools, wire protocol fee providers, configure pause windows, initialize parameters, and enforce deployment-time constraints.

Core security depends on:

1. Vault accounting matching real economic token balances.
2. BPT supply representing a correct proportional claim on pool assets net of fees.
3. Pool math preserving invariant safety across swaps, joins, exits, and batch swaps.
4. Scaling factors, rate providers, and rounding directions not creating systematic value leakage.
5. Privileged configuration remaining bounded, time-scoped, and non-extractive.
6. Pause and recovery mechanisms preserving user exitability during abnormal states.
7. External integrations not relying on manipulable or temporarily inconsistent Balancer state.

---

## 2. Actors and Trust Levels

### Governance / Protocol Fee Provider Admin

Sets protocol-wide fee parameters, fee recipients, factory configuration, pause-related controls, and deployment wiring.

Trust level: `trusted`

Primary risks:

- Misconfigured fee provider
- Excessive protocol fee settings
- Fee changes that break pool math or block exits
- Incorrect factory deployment wiring
- Emergency controls that are unavailable or overpowered

### Pool Owner / Manager

Controls privileged parameters for Managed Pools, LBPs, and potentially other configurable pools. May adjust weights, add or remove tokens, set swap fees, schedule parameter ramps, and configure pool-specific behavior within limits.

Trust level: `partially_trusted`

Primary risks:

- Theft-by-parameter
- Instantaneous value transfer through weight or fee changes
- Unsafe token add/remove
- Broken ramp monotonicity
- Trapped-fund states
- Abuse of manager privileges around thin liquidity or oracle consumers

### Asset Manager

Controls or reports managed balances for pool tokens where assets can move between Vault cash and externally managed positions.

Trust level: `trusted` or `partially_trusted`, depending on deployment

Primary risks:

- Phantom managed balances
- Cash shortage during exits
- Managed balance overstatement
- Stranded liquidity
- Accounting mismatch between Vault records and real controllable assets
- Asset manager failure causing pool insolvency or exit DoS

### Liquidity Provider

Supplies assets through joins and receives BPT as a claim on pool assets. Exits by burning BPT.

Trust level: `untrusted`

Primary risks posed by LP:

- Join/exit sequencing exploitation
- Rounding extraction
- Fee realization timing games
- Single-token join/exit manipulation
- Donation or imbalance attacks
- Exploiting stale rates or stale fee caches

### Trader / Arbitrageur

Swaps through the Vault and economically exploits any pricing, accounting, rounding, or state-transition inconsistency.

Trust level: `untrusted`

Primary risks posed by trader:

- Invariant-breaking swaps
- `batchSwap` netting exploitation
- Sandwiching joins/exits
- Cross-pool cyclic extraction
- Rate or oracle manipulation
- Flash-loan-assisted attacks

### Relayer

A third party authorized to act on behalf of users for Vault operations.

Trust level: `untrusted unless explicitly authorized`

Primary risks:

- Improper authorization checks
- Confused sender / recipient semantics
- Abuse of internal balances
- Unauthorized joins, exits, swaps, or transfers
- Replay or stale approval assumptions
- Incorrect handling of `funds.sender` and `funds.recipient`

### External ERC20 Token

Any token accepted by a pool. Tokens may have non-standard behavior.

Trust level: `unknown`

Risky token behaviors:

- Fee-on-transfer
- Rebasing
- ERC777-style callbacks
- Non-standard return values
- Blacklist / pause / transfer restriction
- Dynamic decimals or proxy behavior
- Balance changes outside Vault-controlled transfers
- Malicious `transfer` / `transferFrom` behavior

### Rate Provider

External or pool-associated component that reports exchange rates for rate-scaled tokens, yield-bearing tokens, boosted pools, or linear pools.

Trust level: `unknown` or `partially_trusted`

Primary risks:

- Stale rates
- Manipulated rates
- Rounding drift in rate scaling
- Sudden rate discontinuities
- External call failure causing join/exit/swap DoS
- Rate used inconsistently between swap, join, exit, and fee logic

### External Integrator / Oracle Consumer

External protocols that read Balancer state, such as BPT price, pool rate, invariant, balances, or `getRate()` output.

Trust level: `untrusted consumer`

Primary risks:

- Using Balancer pool state as an oracle without manipulation resistance
- Reading temporarily inconsistent state
- Read-only reentrancy exposure
- Using stale BPT supply, stale Vault balances, or stale fee state
- Assuming pool rate is safe collateral valuation

### Pool Contract

Implements pool-specific pricing and accounting callbacks such as `onSwap`, join logic, exit logic, invariant calculations, and fee behavior.

Trust level: `partially_trusted`

Primary risks:

- Incorrect math
- Inconsistent rounding
- Unsafe callback sequencing
- Malicious or faulty pool implementation
- Factory misconfiguration
- Pool-specific logic bypassing Vault-level assumptions

---

## 3. Trust Boundaries

### ERC20 Semantics Boundary

The Vault and pools interact with external ERC20 tokens. Token behavior may not match simple ERC20 assumptions.

Security requirement:

- Vault accounting must not assume that nominal transfer amount always equals actual received amount unless the pool explicitly restricts token types.
- Fee-on-transfer, rebasing, callback-enabled, and transfer-restricted tokens must not desynchronize internal accounting from real balances.

Failure modes:

- Join credits more value than received.
- Exit transfers more value than backed.
- Swap balance deltas become incorrect.
- Reentrancy occurs during token transfer.
- Recovery exit is blocked by token behavior.

### Pool Hook Boundary

The Vault delegates pricing and amount computation to pool logic.

Security requirement:

- Pool callback outputs must remain invariant-safe, fee-consistent, and reentrancy-safe.
- Vault must not trust pool outputs beyond validated bounds.

Failure modes:

- Pool hook returns extractive amount.
- Pool math violates invariant.
- Callback observes partially updated state.
- Malicious pool attempts nested Vault interaction.
- Join/exit callback desynchronizes BPT supply and Vault balances.

### Vault Settlement / Internal Balance Boundary

The Vault supports external token transfers, internal balances, sender/recipient separation, batchSwap netting, and relayer execution.

Security requirement:

- Every value movement must be attributable to a real external transfer, internal balance movement, authorized managed-balance mutation, or explicitly accounted fee.
- Internal balances must not let users satisfy obligations without prior legitimate funding.
- `sender` and `recipient` semantics must be enforced consistently.

Failure modes:

- User swaps using another user’s internal balance.
- Relayer bypasses authorization.
- batchSwap nets deltas incorrectly.
- Asset index mismatch sends value to wrong token.
- Recipient receives value before input obligation is finalized.

### Relayer Authorization Boundary

Relayers can execute Vault operations for users only if properly authorized.

Security requirement:

- Relayer permissions must be explicit, user-scoped, and operation-safe.
- Authorization must bind the actual sender, recipient, operation, and token flow assumptions.

Failure modes:

- Unauthorized movement of user funds
- Confused-deputy attacks
- Approval replay
- Operation substitution
- Sender/recipient mismatch

### Asset Manager Boundary

Managed balances represent pool-owned assets not directly held as Vault cash.

Security requirement:

- Transitions between cash and managed balances must preserve total pool-owned value.
- Managed balances must not create phantom liquidity.
- User exits must not depend on unavailable managed assets unless explicitly handled.

Failure modes:

- Managed balance overstated
- Vault thinks pool is solvent while cash is insufficient
- Asset manager withdraws or reports incorrectly
- LPs cannot exit despite apparent pool solvency
- Trader receives assets backed only by accounting entries

### Rate Provider Boundary

Rate providers affect scaling, pricing, fee realization, and valuation of yield-bearing or wrapped assets.

Security requirement:

- Rate inputs must be fresh, bounded, monotonic where expected, and consistently applied across swap/join/exit/fee paths.
- External rate failures must not silently corrupt accounting.

Failure modes:

- Stale rate creates mispriced joins/exits.
- Manipulated rate inflates BPT price.
- Rate update timing enables extraction.
- Rate discontinuity breaks invariant assumptions.
- Fee calculation uses different rate basis than pool math.

### Governance / Factory Boundary

Factories and governance configure pool creation, protocol fees, pause windows, fee providers, and initial parameters.

Security requirement:

- Factories must initialize pools with valid parameters and correct external dependencies.
- Governance-controlled changes must remain bounded and not instantly violate invariants or user exitability.

Failure modes:

- Wrong Vault address
- Wrong ProtocolFeeProvider
- Incorrect pause window
- Invalid weight or amp parameter
- Broken initial BPT mint
- Pool registration mismatch
- Fee update blocks exits or overcharges users

### External Integration / Oracle Boundary

External protocols may read Balancer pool state and treat it as a price, rate, or collateral valuation.

Security requirement:

- View functions and rate functions should not expose temporarily inconsistent or trivially manipulable values.
- External integrators must account for manipulation risk, read-only reentrancy risk, and fee-state staleness.

Failure modes:

- External lending protocol overvalues BPT collateral.
- Read-only reentrancy exposes inflated `getRate()`.
- Pool rate excludes due protocol fees.
- Spot pool balance manipulation affects oracle consumer.
- Composable Stable self-reference distorts valuation.

---

## 4. Economic Primitives

### Vault Cash Balances

ERC20 balances directly custodied by the Vault for each pool token.

Security properties:

- Must correspond to actual token balances controlled by the Vault.
- Must update exactly with joins, exits, swaps, flash loans, and managed-balance movements.
- Must not be inflated by non-standard token behavior.

### Managed Balances

Balances economically owned by a pool but delegated to an asset manager or tracked outside direct Vault cash.

Security properties:

- Cash + managed balances must equal total pool-owned value.
- Managed balance increases must be authorized and backed.
- Managed withdrawals must not strand pool exits.
- Managed accounting must not create phantom liquidity.

### BPT Supply

Balancer Pool Token supply representing LP pro-rata claims.

Security properties:

- Minting must correspond to real value added.
- Burning must correspond to value removed.
- Protocol fee minting must dilute LPs only according to fee rules.
- Supply must be coherent with pool assets net fees.
- For Composable Stable Pools, BPT-as-pool-token must not create self-referential manipulation.

### Pool Invariant

Mathematical pricing function used by the pool family.

Examples:

- Weighted constant-product-style invariant
- Stable swap invariant
- Composable Stable invariant
- Linear pool rate-adjusted invariant

Security properties:

- Swaps must not violate invariant constraints.
- Joins/exits must price BPT fairly.
- Rounding must be consistently biased against the actor who could extract value.
- Multi-step cycles must not create profit absent external price movement.

### Scaling Factors / Rates

Conversion layer between raw token amounts and internal normalized math amounts.

Security properties:

- Decimal scaling must be consistent.
- Rate scaling must be fresh and bounded.
- Upscaling and downscaling must use safe rounding directions.
- Scaling must not overflow or truncate in exploitable ways.
- Same economic amount must not map to different internal values across paths.

Canonical flow:

    raw token amount
      -> scaled amount
      -> rate-adjusted amount
      -> invariant math amount
      -> rounded output
      -> raw token transfer

### Protocol Fees

Protocol-level fees charged on swaps, yield, invariant growth, or other fee bases depending on pool type.

Security properties:

- Fees must be charged exactly once.
- Fees must accrue to the correct party.
- Fees must not be bypassed through join/exit variants.
- Fee caches must not become stale in exploitable ways.
- Fee realization must not allow timing extraction.

### Swap Fees

Pool-level trading fees charged to traders and benefiting LPs or protocol fee recipients depending on configuration.

Security properties:

- Fee direction must be correct for exact-in and exact-out swaps.
- Fee rounding must not enable extraction.
- Fee changes must remain bounded.
- Fees must be consistently applied across batch swaps and single swaps.

### Pause / Recovery Mode

Emergency controls intended to reduce blast radius and preserve exitability.

Security properties:

- Pause windows must be enforced.
- Sensitive operations must respect pause state.
- Recovery mode must allow safe proportional exits.
- Recovery mode should minimize reliance on complex pool math and external rate providers.
- Pausing must not permanently trap funds.

---

## 5. Pool-Type Risk Matrix

### Weighted Pools

Core mechanism:

- Weighted invariant with normalized token weights.
- Swap pricing depends on balances and weights.
- Joins/exits may be proportional or single-token.

Main risks:

- Exponent / power math precision errors
- Weight bounds violation
- Rounding leakage in single-token joins/exits
- Spot price discontinuity after parameter changes
- Protocol fee realization based on invariant growth
- Small repeated operations extracting rounding dust
- Donation or imbalance affecting BPT pricing

High-value questions:

- Are weights normalized and bounded?
- Can a swap violate the weighted invariant after fees?
- Are joins and exits consistently rounded against the user?
- Can protocol fees be avoided through join/exit sequencing?
- Can thin liquidity produce extreme price or invariant behavior?

### Stable Pools

Core mechanism:

- Stable swap invariant optimized for highly correlated assets.
- Amplification parameter controls curvature.

Main risks:

- Amp misconfiguration or unsafe ramping
- Precision loss near balance equality
- Rounding leakage in near-peg swaps
- Invariant calculation convergence failure
- Incorrect handling of imbalance
- Depeg scenarios causing unexpected extraction or DoS

High-value questions:

- Is amp bounded and ramped safely?
- Does invariant calculation converge under extreme imbalance?
- Are exact-in and exact-out paths symmetric within expected rounding?
- Can depeg or imbalance break exit assumptions?
- Can pool math overvalue one asset during stressed conditions?

### Composable Stable Pools

Core mechanism:

- Stable pool where BPT itself may be one of the pool tokens.
- Enables composability but introduces self-referential supply/balance logic.

Main risks:

- BPT-in-pool self-reference
- Phantom BPT accounting mistakes
- Incorrect BPT supply used for pricing
- Joins/exits manipulating BPT balance and total supply simultaneously
- Protocol fee calculation using wrong supply base
- `getRate()` manipulation
- Read-only reentrancy against BPT valuation

High-value questions:

- Is BPT excluded or included correctly in invariant calculations?
- Is the correct virtual supply or effective supply used?
- Can a user manipulate BPT balance inside the pool before mint/burn finalization?
- Do joins/exits update BPT supply and Vault balances in safe order?
- Does `getRate()` include due fees, phantom BPT, and current balances correctly?
- Can external protocols safely consume the reported rate?

### Managed Pools

Core mechanism:

- Pool owner can adjust weights, token set, fees, and other parameters subject to rules.

Main risks:

- Token add/remove corrupting registry
- Storage packing / bit offset errors
- Weight sum not equal to 1
- Instant value shifts from parameter changes
- Manager privilege abuse
- Removal of token with outstanding balances
- Exit blocked after token mutation
- Scaling factor mismatch for newly added tokens

High-value questions:

- Are token lists sorted and indexed consistently?
- Does add/remove preserve normalized weights and scaling?
- Are minimum BPT supply and invariant continuity preserved?
- Can a manager remove a token and strand value?
- Are ramps monotonic and bounded?
- Can manager actions bypass pause or recovery constraints?

### Liquidity Bootstrapping Pools

Core mechanism:

- Weight schedule changes over time to support token launches and price discovery.

Main risks:

- Incorrect weight interpolation
- Retroactive schedule modification
- Privileged timing extraction
- Front-running around weight updates
- Launch price manipulation
- Pause or buffer misuse during sale period

High-value questions:

- Are start/end weights and times validated?
- Is weight motion monotonic?
- Can the owner shorten or alter schedule to extract value?
- Can trades around scheduled updates create unintended free value?
- Does pause behavior interact safely with ongoing sale mechanics?

### Linear / Boosted Pools

Core mechanism:

- Pools involving wrapped yield-bearing assets, rate providers, or boosted liquidity.

Main risks:

- Stale rate provider
- Wrapped token exchange-rate manipulation
- Main/wrapped token imbalance
- Incorrect target range behavior
- Yield fee misaccounting
- Rate discontinuity causing BPT mispricing
- External protocol dependency failure

High-value questions:

- Is rate provider trusted, bounded, and fresh?
- Can rate be manipulated within one transaction?
- Are wrapped and underlying balances reconciled safely?
- Are yield fees charged exactly once?
- Can stale rates allow cheap join or expensive exit?
- Does recovery mode avoid unsafe rate dependencies?

---

## 6. Critical State Transitions

### Join

Category: value in / share issuance

Flow:

1. User specifies pool, assets, amounts, and recipient.
2. Vault/pool computes required token inputs and BPT out.
3. Tokens are transferred or internal balances are debited.
4. Vault balances are updated.
5. BPT is minted.

Security requirements:

- BPT mint must correspond to actual value received.
- Fee-on-transfer tokens must not overcredit input.
- Internal balance usage must be authorized.
- Rounding must not favor the joiner.
- Protocol fee realization must be correct before/after mint.
- Reentrancy must not observe intermediate BPT supply or balances.

Failure modes:

- Free or underpriced BPT mint
- LP dilution
- Fee bypass
- Join with insufficient actual token transfer
- Manipulation of pool rate before mint

### Exit

Category: value out / share redemption

Flow:

1. User burns BPT or authorizes BPT burn.
2. Pool computes token amounts out.
3. Vault balances are updated.
4. Tokens are transferred to recipient or credited internally.

Security requirements:

- Burned BPT must correspond to value removed.
- Exit amounts must be backed by real assets.
- Managed balances must not overstate exit liquidity.
- Rounding must not favor the exiting LP.
- Exit must remain possible in recovery mode.

Failure modes:

- Over-redemption
- Exit DoS
- Under-collateralized pool
- User receives wrong token or recipient
- Protocol fees double-charge or block exit

### Swap

Category: trade settlement

Flow:

1. Trader submits token in/out and amount constraints.
2. Vault calls pool pricing logic.
3. Fees are applied.
4. Vault updates balances and transfers tokens.

Security requirements:

- Swap output must satisfy invariant and fee rules.
- Exact-in and exact-out semantics must be correct.
- Token transfers must match balance deltas.
- Reentrancy must be blocked.
- Pool hook output must be bounded.

Failure modes:

- Invariant violation
- Incorrect fee direction
- Output exceeds backed liquidity
- Toxic rounding cycle
- Token transfer mismatch

### batchSwap

Category: multi-hop net settlement

Flow:

1. User submits multiple swap steps and asset list.
2. Vault computes per-asset net deltas.
3. Internal and external balances settle only net obligations.
4. Recipient receives net outputs.

Security requirements:

- Asset indexes must map to correct tokens.
- Delta signs must be correct.
- Netting must not create phantom intermediate liquidity.
- Limits must be enforced per asset.
- Relayer/internal balance permissions must be honored.
- Multi-hop swaps must not bypass per-pool invariant constraints.

Failure modes:

- Sign error in asset delta
- Wrong asset index
- User receives output without paying required input
- Intermediate hop uses nonexistent liquidity
- Relayer drains approved balance
- Rounding leakage across many hops

### Flash Loan

Category: temporary liquidity

Flow:

1. Vault transfers assets to borrower.
2. Borrower callback executes arbitrary logic.
3. Vault verifies repayment plus fee.

Security requirements:

- Repayment must be verified using actual balances.
- Fee must be charged exactly once.
- Borrower callback must not reenter unsafe paths.
- Flash loan must not desynchronize pool accounting.

Failure modes:

- Under-repayment accepted
- Fee bypass
- Reentrancy into join/exit/swap
- Balance manipulation during callback
- Token behavior prevents repayment accounting

### managePoolBalance

Category: managed balance mutation

Flow:

1. Authorized asset manager moves assets between cash and managed balances or updates managed accounting.
2. Vault records updated balance state.
3. Pool accounting uses new cash/managed composition.

Security requirements:

- Only authorized asset manager can mutate managed balances.
- Total pool-owned value must be conserved.
- Managed increases must be backed.
- Cash decreases must not break user exitability.

Failure modes:

- Phantom liquidity
- Cash shortage
- Unauthorized managed balance update
- Stranded assets
- Mispriced joins/exits due to stale managed value

### Add / Remove Token

Category: pool composition mutation

Flow:

1. Pool manager modifies token registry.
2. Weights, scaling factors, and balances update.
3. Pool invariant and BPT supply assumptions must remain coherent.

Security requirements:

- Token registry remains sorted and consistent.
- Removed token balances are handled safely.
- Weights remain normalized.
- Scaling factors are correct.
- No value is created or stranded.

Failure modes:

- Token index corruption
- Wrong scaling factor
- Removed token still has claimable value
- LP exits broken
- Storage packing corruption

### Parameter Ramp

Category: privileged reparameterization

Examples:

- Weight ramp
- Amp ramp
- Fee ramp if supported
- LBP schedule

Security requirements:

- Start and end parameters must be bounded.
- Schedule must be monotonic.
- Time windows must not be retroactively changed to create instant shifts.
- Parameter updates must not violate invariant assumptions.

Failure modes:

- Theft-by-parameter
- Instant arbitrage against LPs
- Pool insolvency or DoS
- Negative or invalid weights
- Amp discontinuity causing mispricing

### Fee Collection / Fee Realization

Category: protocol and pool fee accounting

Security requirements:

- Fees charged exactly once.
- Fee base is correct.
- Fee recipient is correct.
- Cached fee values cannot be exploited.
- Join/exit/swap timing cannot avoid or duplicate fees.

Failure modes:

- Undercollection
- Overcollection
- LP dilution
- Protocol fee recipient loss
- Exit blocked by excessive fee
- Timing attack around fee update

### Recovery Exit

Category: emergency value out

Security requirements:

- Users must be able to exit proportionally during recovery mode.
- Recovery exit should avoid complex math and unsafe external dependencies where possible.
- Protocol fees and BPT accounting must not block recovery.
- Pause state must not prevent intended emergency exits.

Failure modes:

- Funds trapped during emergency
- Recovery exit overpays or underpays
- External rate provider failure blocks exit
- Token behavior causes recovery DoS
- Recovery mode bypasses intended accounting constraints

---

## 7. Accounting Anchors

### A1. Vault Balance Conservation

For every pool and token:

    Vault balance delta
      = actual token movement
      + internal balance movement
      + authorized managed balance movement
      + explicitly accounted fees

Security objective:

- Internal Vault balances must match economic reality.

Review focus:

- joins
- exits
- swaps
- batch swaps
- flash loans
- internal balances
- managed balances
- protocol fee movements

### A2. BPT Supply Coherence

BPT supply must represent proportional claim on pool assets net of fees.

Security objective:

- Minting and burning BPT must never create unbacked claims or destroy user claims incorrectly.

Review focus:

- BPT mint on join
- BPT burn on exit
- protocol fee minting
- minimum BPT supply
- Composable Stable BPT-in-pool
- BPT rate calculation
- due protocol fees

### A3. Invariant Safety

Given pool balances, weights/rates/amp, and fees:

    post-operation invariant must be valid

Security objective:

- No swap, join, or exit should extract value beyond the intended fee model.

Review focus:

- weighted math
- stable math
- exact-in / exact-out symmetry
- single-token joins/exits
- multi-hop swaps
- extreme imbalance
- depeg conditions

### A4. Fee Single-Charge

Fees must be charged:

    exactly once
    to the correct party
    on the correct base
    at the correct time

Security objective:

- No fee bypass, double-charge, stale-cache extraction, or incorrect fee recipient accounting.

Review focus:

- swap fees
- protocol swap fees
- yield fees
- due protocol fees
- fee cache updates
- join/exit timing
- governance fee changes

### A5. Scaling / Rounding Monotonicity

Scaling and rounding must not create systematic value.

Security objective:

- Repeated operations must not produce positive expected value solely due to precision boundaries.

Review focus:

- decimals scaling
- rate scaling
- upscaling/downscaling
- rounding direction
- token decimals difference packing
- exact-in vs exact-out
- batchSwap repeated rounding
- stable math near equality

### A6. Managed Balance Conservation

For each pool token:

    cash + managed = total pool-owned value

Security objective:

- Managed accounting must not create phantom solvency or strand user assets.

Review focus:

- managePoolBalance
- asset manager permissions
- cash to managed movements
- managed to cash movements
- exits under low cash
- emergency recovery
- pool valuation using managed balances

### A7. Recovery Exit Correctness

During recovery mode:

    user's proportional claim must remain withdrawable

Security objective:

- Emergency controls must preserve user exitability without creating new extraction paths.

Review focus:

- proportional exit math
- pause interactions
- protocol fee interactions
- BPT supply base
- rate provider dependence
- token transfer failure
- managed balance availability

### A8. Relayer / Internal Balance Authorization

Every operation using internal balances or relayer execution must be explicitly authorized.

Security objective:

- No user funds should move due to confused-deputy authorization, stale approvals, or sender/recipient mismatch.

Review focus:

- relayer approval
- `funds.sender`
- `funds.recipient`
- internal balance debit
- internal balance credit
- batchSwap netting
- delegated joins/exits/swaps

### A9. Read-Only State Consistency

View functions used by external integrators must not expose unsafe intermediate state.

Security objective:

- External protocols should not be able to observe inflated, stale, or inconsistent rates during Vault-context operations.

Review focus:

- `getRate()`
- BPT price
- invariant
- total supply
- Vault balances
- due protocol fees
- read-only reentrancy
- Composable Stable self-reference

---

## 8. Threat Surfaces

### Accounting Desync via Non-Standard ERC20s

Mechanism:

- Token transfer behavior differs from nominal amount assumptions.

Attack paths:

- Join credits full amount despite fee-on-transfer.
- Exit pays out from overstated accounting.
- Rebase changes Vault balance without internal update.
- ERC777 hook reenters during transfer.

Potential impact:

- LP dilution
- Pool insolvency
- Swap under-collateralization
- DoS

Priority: `critical`

### Reentrancy / Read-Only Reentrancy

Mechanism:

- External token transfers, pool hooks, flash-loan callbacks, or BPT interactions expose partially updated state.

Attack paths:

- Nested join/exit/swap observes stale balances.
- External integrator reads inflated BPT rate.
- Protocol fee state is not updated before rate read.
- Pool callback reenters through alternate path.

Potential impact:

- Double-withdraw
- Fee bypass
- Oracle manipulation
- External protocol loss
- Accounting desync

Priority: `critical`

### Composable Stable BPT Self-Reference

Mechanism:

- BPT is itself part of the pool’s token set.

Attack paths:

- Manipulate BPT balance inside pool before supply update.
- Exploit difference between total supply and effective supply.
- Abuse phantom BPT accounting.
- Trigger incorrect `getRate()` output.
- Join/exit around protocol fee realization.

Potential impact:

- BPT mispricing
- LP dilution
- External oracle loss
- Incorrect fee collection
- Pool insolvency

Priority: `critical`

### Rate Provider Stale or Manipulated Rates

Mechanism:

- Pool math or BPT valuation depends on external rate input.

Attack paths:

- Join with undervalued asset.
- Exit with overvalued asset.
- Manipulate rate within same transaction.
- Use stale rate during market stress.
- Rate discontinuity breaks invariant.

Potential impact:

- Value extraction
- Mispriced BPT
- Yield fee misaccounting
- External integrator loss
- Exit DoS

Priority: `high`

### Relayer / Internal Balance Authorization Bugs

Mechanism:

- Vault supports delegated operations and internal accounting.

Attack paths:

- Relayer uses stale approval.
- Sender/recipient fields confused.
- Internal balance debit taken from wrong user.
- batchSwap net settlement credits wrong recipient.
- Authorization does not bind operation parameters.

Potential impact:

- Direct user fund loss
- Unauthorized swaps
- Unauthorized joins/exits
- Accounting mismatch

Priority: `critical`

### batchSwap Netting / Asset Index Errors

Mechanism:

- batchSwap uses asset arrays, per-step indexes, and net settlement.

Attack paths:

- Incorrect sign convention.
- Asset index mismatch.
- Multi-hop path creates phantom intermediate liquidity.
- Limit checks applied to wrong asset.
- Rounding leakage across many swap steps.

Potential impact:

- Free output
- Underpayment
- Wrong-token settlement
- Pool drain
- DoS

Priority: `critical`

### Factory / Initialization Mistakes

Mechanism:

- Factories wire Vault, fee provider, pause windows, pool parameters, and initial token configuration.

Attack paths:

- Pool deployed with invalid parameter bounds.
- Wrong fee provider.
- Wrong pause window.
- Invalid initial weights or amp.
- Token registration mismatch.
- Minimum BPT supply not enforced.

Potential impact:

- Broken pool at launch
- Fee loss
- Pause failure
- Invariant break
- LP loss

Priority: `high`

### Privileged Parameter Abuse

Mechanism:

- Pool owner or governance can change economically meaningful parameters.

Attack paths:

- Weight jump.
- Amp jump.
- Fee spike.
- Token removal with value.
- LBP schedule manipulation.
- Pause used to trap funds.

Potential impact:

- Value transfer from LPs/traders
- DoS
- Loss of user exitability
- Governance abuse

Priority: `high`

### Pause / Recovery Failure

Mechanism:

- Emergency controls fail to activate, activate too broadly, or block exits.

Attack paths:

- Sensitive operation bypasses pause.
- Pause allowed after pause window.
- Unpause impossible.
- Recovery exit blocked by fee/rate/token behavior.
- Recovery exit overpays due to wrong supply base.

Potential impact:

- Incident cannot be contained
- Funds trapped
- Emergency exit unsafe
- Governance operational failure

Priority: `high`

### Protocol Fee Realization Timing Mismatch

Mechanism:

- Fees are realized lazily or depend on cached invariant/rate/supply state.

Attack paths:

- Join before fee realization, exit after.
- Exit before fee realization, avoiding dilution.
- Governance fee update creates stale cache.
- Composable Stable supply base mismeasured.
- Fees charged twice across join/exit boundary.

Potential impact:

- LP dilution
- Protocol revenue loss
- User overcharge
- BPT mispricing

Priority: `high`

### Oracle / Integration Risk

Mechanism:

- External protocols consume Balancer rates, balances, or BPT prices.

Attack paths:

- Flash-loan manipulates pool balances.
- Read-only reentrancy exposes inconsistent state.
- `getRate()` excludes due fees.
- Pool rate depends on stale rate provider.
- Thin pool used as collateral oracle.

Potential impact:

- External lending protocol bad debt
- Incorrect collateral valuation
- Liquidation manipulation
- Cascading DeFi loss

Priority: `high`

---

## 9. High-Value Review Questions

### Vault Accounting

1. For each join/exit/swap path, where exactly are Vault cash balances updated?
2. Are actual ERC20 transfers reconciled against internal accounting?
3. Can fee-on-transfer or rebasing tokens create balance mismatch?
4. Are managed balances included correctly in pool valuation?
5. Can Vault internal balances satisfy obligations without proper authorization?
6. Does batchSwap net settlement preserve per-asset conservation?

Suggested tests:

- Fee-on-transfer join test
- Rebasing token balance drift test
- Internal balance debit authorization test
- batchSwap net delta conservation fuzz
- cash + managed conservation invariant

### BPT Supply

1. Can BPT be minted before token input is finalized?
2. Can BPT be burned after token output is already transferred?
3. Does BPT supply include or exclude protocol fee claims correctly?
4. Is minimum BPT supply enforced?
5. For Composable Stable Pools, is BPT-in-pool handled using correct effective supply?
6. Can BPT rate be manipulated through join/exit sequencing?

Suggested tests:

- Join mint ordering test
- Exit burn ordering test
- Protocol fee dilution test
- Composable Stable BPT effective supply test
- BPT rate manipulation test

### Swap / Invariant Math

1. Do exact-in and exact-out swaps apply fees and rounding consistently?
2. Can a cyclic swap sequence create profit without external price movement?
3. Does invariant hold under extreme imbalance?
4. Are decimal scaling and rate scaling applied symmetrically?
5. Can batchSwap amplify rounding leakage?
6. Does stable invariant converge under stressed conditions?

Suggested tests:

- Exact-in/exact-out roundtrip loss test
- Multi-hop no-free-value invariant
- Extreme imbalance invariant test
- Decimal scaling fuzz
- Stable depeg scenario test

### Composable Stable

1. How is BPT excluded from or included in invariant calculations?
2. Is effective supply computed safely?
3. Does `getRate()` include due protocol fees?
4. Can BPT balance inside the pool be manipulated before rate read?
5. Does read-only reentrancy affect BPT valuation?
6. Are joins/exits safe when BPT is both supply and pool asset?

Suggested tests:

- BPT-in-pool supply reconciliation test
- `getRate()` before/after fee realization test
- Read-only reentrancy rate test
- Join/exit BPT self-reference test

### Rate Providers / Linear / Boosted Pools

1. What happens if rate provider reverts?
2. What happens if rate is stale?
3. Can rate change within one transaction?
4. Are rate-scaled amounts rounded consistently?
5. Does yield fee use the same rate basis as pool math?
6. Can recovery exit bypass broken rate provider dependency?

Suggested tests:

- Stale rate join/exit arbitrage test
- Rate discontinuity test
- Rate provider revert recovery test
- Yield fee single-charge test

### Relayers / Internal Balances

1. Is relayer authorization checked for every delegated operation?
2. Does authorization bind sender, recipient, and operation?
3. Can internal balance of one user be spent for another?
4. Can relayer redirect swap output?
5. Are internal balance credits/debits included in batchSwap net limits?
6. Are approvals replayable or overly broad?

Suggested tests:

- Unauthorized relayer swap test
- Sender/recipient confusion test
- Internal balance debit isolation test
- batchSwap relayer redirect test

### Managed Pools / Asset Managers

1. Can managed balances be increased without backing?
2. Can cash be moved to managed such that exits fail?
3. Does cash + managed remain conserved?
4. Can token add/remove corrupt weights or scaling?
5. Are token indexes and storage packing safe?
6. Can manager actions bypass pause or recovery behavior?

Suggested tests:

- Managed balance phantom liquidity test
- Exit with low cash / high managed balance test
- Token add/remove weight sum invariant
- Storage packing fuzz
- Manager privilege boundary test

### Parameter Ramps / LBP

1. Are start/end times validated?
2. Are weights or amp values monotonic over time?
3. Can owner shorten or alter ramp to create instant value transfer?
4. Are parameter bounds enforced at creation and update?
5. Can swaps around ramp boundary extract value?
6. Does pause interact safely with active ramp?

Suggested tests:

- Weight ramp monotonicity fuzz
- Amp ramp discontinuity test
- LBP schedule mutation test
- Swap around ramp boundary test

### Pause / Recovery

1. Are pause windows and buffer periods enforced exactly?
2. Can alternate entrypoints bypass pause?
3. Can users exit during recovery mode?
4. Does recovery exit avoid unsafe external dependencies?
5. Does recovery mode use correct BPT supply base?
6. Can protocol fees block emergency exits?

Suggested tests:

- Pause bypass test across swap/join/exit
- Recovery proportional exit test
- Recovery with broken rate provider test
- Recovery after protocol fee accrual test

### External Integrations / Oracle Consumers

1. Is `getRate()` safe during Vault-context operations?
2. Does BPT valuation include due protocol fees?
3. Can pool balances be flash-loan manipulated before external read?
4. Are rates based on spot balances or manipulation-resistant values?
5. Can read-only reentrancy expose transiently inflated state?
6. What assumptions must external protocols make before using Balancer pool state?

Suggested tests:

- Read-only reentrancy rate manipulation test
- Flash-loan spot manipulation test
- Due-fee-adjusted rate test
- External oracle consumer mock exploit

---

## 10. Repo Context

### Analyzer

- `evm`

### Source Repo Shape

- `foundry / hardhat monorepo`

### Preferred Audit Workspace Shape

- `foundry`

### Runtime

- `evm`

### Language

- `solidity`

### Frameworks

- `foundry`
- `hardhat`

### Primary Code Surfaces

#### Vault Accounting

Files:

- `pkg/vault/contracts/PoolTokens.sol`
- `pkg/vault/contracts/balances/TwoTokenPoolsBalance.sol`

Focus:

- cash balances
- managed balances
- token registration
- balance updates
- internal balance interaction
- join/exit/swap settlement

#### Vault Reentrancy / External Call Boundaries

Files:

- `pkg/pool-utils/contracts/lib/VaultReentrancyLib.sol`

Focus:

- Vault lock assumptions
- read-only reentrancy
- pool callback boundaries
- external integration safety

#### BPT Implementation

Files:

- `pkg/pool-utils/contracts/BalancerPoolToken.sol`

Focus:

- mint/burn
- supply coherence
- allowances
- transfer behavior
- Composable Stable self-reference

#### Factories / Deployment

Files:

- `pkg/pool-utils/contracts/factories/BasePoolFactory.sol`
- `pkg/pool-utils/contracts/factories/FactoryWidePauseWindow.sol`
- `pkg/pool-weighted/contracts/WeightedPoolFactory.sol`
- `pkg/pool-stable/contracts/ComposableStablePoolFactory.sol`
- `pkg/pool-weighted/contracts/managed/ManagedPoolFactory.sol`
- `pkg/pool-weighted/contracts/lbp/LiquidityBootstrappingPoolFactory.sol`

Focus:

- fee provider wiring
- Vault address wiring
- pause windows
- initialization parameters
- pool-specific bounds
- deployment invariants

#### Weighted Pools

Files:

- `pkg/pool-weighted/contracts/WeightedPoolFactory.sol`
- `pkg/pool-weighted/contracts/lbp/LiquidityBootstrappingPoolFactory.sol`
- `pkg/pool-weighted/contracts/managed/ManagedPoolFactory.sol`
- `pkg/pool-weighted/contracts/managed/ManagedPoolAddRemoveTokenLib.sol`
- `pkg/pool-weighted/contracts/managed/ManagedPoolTokenStorageLib.sol`

Focus:

- weighted invariant
- weight ramps
- token add/remove
- storage packing
- LBP schedule
- managed-pool privileges

#### Stable / Composable Stable Pools

Files:

- `pkg/pool-stable/contracts/ComposableStablePoolFactory.sol`

Focus:

- stable invariant
- amp parameter
- BPT-in-pool logic
- effective supply
- `getRate()`
- protocol fee realization
- scaling factors

#### Rate / Linear / Boosted Pools if in Scope

Potential focus:

- RateProvider interfaces
- Linear Pool contracts
- Boosted Pool contracts
- Composable Stable integration with rate-scaled assets

Focus:

- stale rates
- manipulated rates
- wrapped-token exchange rate
- yield fee accounting
- recovery behavior under rate failure

---

## 11. Suggested Review Priority

### P0: Must Review

- Vault cash/managed balance accounting
- BPT mint/burn coherence
- join/exit/swap settlement sequencing
- batchSwap netting
- reentrancy and read-only reentrancy
- Composable Stable BPT self-reference
- recovery exit correctness

### P1: High Value

- protocol fee realization
- rate provider surfaces
- scaling / rounding
- relayer/internal balance authorization
- ManagedPool token add/remove
- parameter ramps
- factory initialization

### P2: Contextual / Scope Dependent

- LBP economic launch manipulation
- Linear / Boosted pool rate behavior
- external oracle consumer risks
- governance operational risks
- non-standard token support boundaries

---

## 12. Initial Artifact Plan

### Review Notes

Target file:

- `notes/balancer-v2-review-note.md`

Sections:

- Vault as settlement kernel
- Pool family risk matrix
- BPT supply and pool asset coherence
- Composable Stable self-reference
- Recovery mode and integration risk
- Lessons for DeFi financial security

### Function Notes

Target file:

- `reviews/balancer-v2/function-notes.md`

Suggested function groups:

- Vault join/exit/swap/batchSwap
- PoolTokens balance updates
- TwoTokenPoolsBalance cash/managed accounting
- BalancerPoolToken mint/burn
- ComposableStablePoolFactory initialization
- ManagedPoolAddRemoveTokenLib token mutation
- FactoryWidePauseWindow pause logic
- VaultReentrancyLib view/reentrancy protection

### Invariants

Target file:

- `reviews/balancer-v2/invariants.md`

Candidate invariants:

1. Vault balance conservation
2. cash + managed conservation
3. BPT supply coherence
4. no-free-value roundtrip
5. fee single-charge
6. batchSwap net delta conservation
7. scaling / rounding monotonicity
8. recovery proportional exit correctness
9. Composable Stable effective supply consistency
10. relayer authorization isolation

### Test Targets

Target folder:

- `test/balancer/`

Candidate tests:

- `VaultBalanceConservation.t.sol`
- `BatchSwapNetting.t.sol`
- `BPTSupplyCoherence.t.sol`
- `ComposableStableRate.t.sol`
- `ReadOnlyReentrancyRate.t.sol`
- `ManagedBalanceConservation.t.sol`
- `RecoveryExit.t.sol`
- `RelayerInternalBalanceAuth.t.sol`
- `ScalingRounding.t.sol`
- `ProtocolFeeRealization.t.sol`