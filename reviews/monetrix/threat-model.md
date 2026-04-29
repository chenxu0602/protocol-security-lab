# Monetrix Threat Model

## 1. Protocol Summary

Monetrix is a USDC-backed synthetic dollar protocol on HyperEVM.

The core user-facing flow is:

- Users deposit EVM-side USDC into `MonetrixVault`.
- The Vault mints USDM 1:1 to users.
- Users may stake USDM into `sUSDM`, an ERC-4626-style yield wrapper.
- Yield is generated off-chain / cross-domain and later settled on-chain through `MonetrixAccountant`.
- Settled yield is parked in `YieldEscrow`, then distributed to:
  - sUSDM holders via `sUSDM.injectYield`
  - Insurance Fund
  - Foundation

The backing of USDM is distributed across several accounting domains:

- EVM-side USDC held by `MonetrixVault`
- EVM-side USDC held by `RedeemEscrow`
- L1 spot USDC held by the Vault HyperCore account
- L1 spot USDC / spot assets / perp account value / HLP equity held by the optional `multisigVault` HyperCore account
- L1 whitelisted spot hedge assets valued in USDC
- USDC / spot assets supplied into the Portfolio Margin / 0x811 pool
- Signed perp account value
- HLP equity

The central security challenge is not generic Solidity correctness. It is **balance-sheet correctness across EVM USDC, HyperCore state, redemption escrow, yield settlement, and wrapper accounting**.

The most important implementation fact is:

```text
Protocol solvency is measured by MonetrixAccountant.totalBackingSigned() - USDM totalSupply,
with pending redemption shortfall subtracted again when determining distributable yield.
```

This means the review should focus on:

- whether backing is counted exactly once
- whether liabilities are represented exactly once
- whether unsettled or illiquid value can be distributed as if it were realized EVM USDC
- whether async queues (`RedeemEscrow`, `sUSDMEscrow`) preserve claims without creating phantom assets

---

## 2. Main Trust Boundaries

### 2.1 User Boundary

Users are untrusted.

Relevant user actions:

- `deposit`
- `requestRedeem`
- `claimRedeem`
- `sUSDM.deposit`
- `sUSDM.mint`
- `sUSDM.cooldownShares`
- `sUSDM.cooldownAssets`
- `sUSDM.claimUnstake`

Key concerns:

- Can users mint unbacked USDM?
- Can users redeem more USDC than their USDM claim?
- Can users use timing around `requestRedeem`, `claimRedeem`, `cooldown*`, or `claimUnstake` to extract value?
- Can users manipulate sUSDM exchange rate transitions around yield injection?
- Can users create obligations that are excluded from solvency checks or included twice?

---

### 2.2 Operator Boundary

The Operator is trusted but instant.

The README explicitly treats Operator as a trusted hot-wallet role. Therefore, pure malicious Operator behavior is not a valid issue unless the bug arises from a contract-level accounting flaw during an otherwise allowed Operator workflow.

Relevant Operator actions:

- `keeperBridge`
- `bridgePrincipalFromL1`
- `bridgeYieldFromL1`
- `settle`
- `distributeYield`
- `fundRedemptions`
- `reclaimFromRedeemEscrow`
- `executeHedge`
- `closeHedge`
- `repairHedge`
- `depositToHLP`
- `withdrawFromHLP`
- `supplyToBlp`
- `withdrawFromBlp`
- `MonetrixAccountant.addMultisigSupplyToken`
- `MonetrixAccountant.removeSuppliedEntry`

Review framing:

- Not valid: "Operator maliciously refuses to fund redemptions."
- Potentially valid: "A normal Operator action sequence allowed by the contract causes under-reserving, double-counted backing, stale supplied-asset accounting, or over-distribution of yield."

Operator-trust does **not** make the following classes of bug irrelevant:

- incorrect reservation logic between bridgeable principal, redemption liquidity, and yield liquidity
- accounting that assumes a correct operator-maintained registry and breaks unsafely when the registry is stale
- routable value that can be moved between accounting domains without corresponding liability updates

---

### 2.3 Governor / Admin Boundary

Governor, DEFAULT_ADMIN, and UPGRADER are trusted / timelocked.

Known issues include:

- Single UPGRADER can replace all proxy implementations.
- Parameters are not final.
- Governor controls config / emergency paths.

Therefore, issues based purely on admin misconfiguration, malicious upgrade, or bad parameter choices are likely out of scope / QA.

Valid admin-adjacent issue shape:

- A parameter setter fails to enforce a hard invariant required for normal operation.
- A config domain mixup allows normal Operator actions to act on the wrong asset.
- A stale config or registry entry remains in accounting after removal and causes wrong backing.
- An emergency path bypasses a critical accounting precondition, not just a policy preference.

Special attention points:

- `setMultisigVault` / `setMultisigVaultEnabled` alter whether a second HyperCore account is included in backing.
- `setPmEnabled` changes how L1 bridgeability is checked.
- `setYieldBps` defines the split between user, insurance, and foundation yield.
- `initializeSettlement` opens the settlement pipeline exactly once.

---

### 2.4 Guardian / Pause Boundary

The protocol has two independent pause surfaces:

- `paused`: freezes user flows and mixed paths such as `deposit`, `claimRedeem`, `keeperBridge`, `settle`, `distributeYield`
- `operatorPaused`: freezes operator-driven mutations such as hedge, HLP, BLP, bridge-back, yield routing, and escrow funding/reclaim

Threat-model significance:

- Review must not assume "paused" and "operatorPaused" protect the same surface.
- The Governor emergency paths intentionally bypass both pause flags.
- Bugs that leave claims inaccessible under one pause mode but not the other are valid operational / liveness risks.

Relevant concerns:

- Can obligations accumulate while the normal path to satisfy them is paused?
- Can an emergency path move assets across domains without preserving accounting invariants?
- Can one pause mode be used to freeze users while still allowing value-moving operator actions that depend on those user liabilities?

---

### 2.5 HyperCore / Precompile Boundary

`MonetrixAccountant` reads L1 state via `PrecompileReader`.

Important precompile domains:

- spot balance
- supplied balance
- account margin summary
- vault equity
- oracle price
- token info
- perp asset info
- spot price metadata boundary through config

Key concern:

The protocol composes several HyperCore data sources into one synthetic balance sheet. Any domain overlap, omission, stale registry entry, or unit mismatch can overstate or understate `totalBackingSigned()`.

Critical review questions:

- Does `accountValueSigned` already include spot collateral or supplied collateral?
- Are supplied balances distinct from spot balances?
- Is HLP equity counted independently from any account value?
- Are spot token balances valued using the correct oracle and decimal convention?
- Are signed values handled correctly?
- Are failed / short precompile responses fail-closed?
- Can the protocol enter a state where backing view functions revert because registry state and actual HL state diverge?

---

### 2.6 Escrow / Queue Boundary

There are three important escrow / routing components:

- `RedeemEscrow`
- `YieldEscrow`
- `sUSDMEscrow`

Security properties:

- `RedeemEscrow.totalOwed` must match outstanding redemption obligations.
- `RedeemEscrow` must not be drained below obligations.
- `YieldEscrow` must only release yield to Vault.
- `sUSDMEscrow` balance must match `sUSDM.totalPendingClaims`.

These escrows do not create new economic value. They only isolate timing and routing of already-existing claims.

---

## 3. Assets and Liabilities

### 3.1 Protocol Assets

These are the assets the accountant actually treats as protocol backing:

- EVM USDC in Vault
- EVM USDC in RedeemEscrow
- L1 spot USDC
- L1 hedge spot assets valued in USDC
- L1 supplied assets valued in USDC
- signed perp account value
- HLP equity
- the same classes of L1 assets held by `multisigVault` when enabled

### 3.2 Items That Are Not New Protocol Assets

These balances matter for local correctness but should not be counted as separate protocol backing:

- USDM held by `sUSDM`
- USDM held by `sUSDMEscrow`
- USDC held by `YieldEscrow`
- USDC held by `InsuranceFund`

Why:

- `sUSDM` and `sUSDMEscrow` only rearrange claims on existing USDM supply.
- `YieldEscrow` holds settled but undistributed USDC that is deliberately excluded from backing.
- `InsuranceFund` is ring-fenced reserve and excluded from user backing.

### 3.3 Protocol Liabilities

Primary liability:

- `USDM.totalSupply()`

Operational sub-claims that matter for distribution / liveness:

- outstanding redemption obligations represented by `RedeemEscrow.totalOwed`
- pending redemption shortfall represented by `RedeemEscrow.shortfall()`
- pending sUSDM unstake claims represented by `sUSDM.totalPendingClaims`

Important distinction:

- `RedeemEscrow.totalOwed` is not an additional protocol-wide liability on top of USDM supply forever; it is a queue-local claim that matters because USDM is not burned until `claimRedeem`.
- `sUSDM.totalPendingClaims` is not a second external liability on top of USDM supply; it is the wrapper's isolated claim on USDM already removed from the active share pool.

### 3.4 Yield State

Yield exists in three different states:

- economic surplus reported by `surplus()`
- yield that passes settlement gates and is transferred into `YieldEscrow`
- yield that is distributed into user / insurance / foundation destinations

Threat-model implication:

- not all positive surplus is immediately distributable
- not all settled yield is backing
- distribution changes both asset locations and, for user share, USDM supply

---

## 4. Core Accounting Model

### 4.1 USDM Minting

User deposits USDC into Vault.

Expected invariant:

```text
USDM minted == USDC received
```

Review questions:

- Can transfer-fee / weird-token behavior break 1:1 mint assumptions?
- Can deposit caps be bypassed?
- Can minting occur before receipt of USDC?

Current code intent is simple and strong because the asset is plain USDC and minting occurs after `safeTransferFrom`.

### 4.2 Redemption Request

User calls `requestRedeem(usdmAmount)`.

State transition:

- user USDM moves to Vault
- `RedeemEscrow.totalOwed += usdmAmount`
- a request is created with cooldown
- USDM is **not** burned yet

This creates a crucial intermediate state:

```text
USDM supply is unchanged
but a separate USDC payout obligation now exists in RedeemEscrow
```

Threats to model:

- phantom yield if the protocol treats queued redemption USDM as already extinguished
- under-reserving EVM USDC for pending claims
- request truncation / overwrite / queue corruption

### 4.3 Redemption Claim

User calls `claimRedeem(requestId)` after cooldown.

State transition:

- request is deleted
- user USDM amount is burned from Vault-held balance
- `RedeemEscrow.payOut` transfers USDC to user
- `RedeemEscrow.totalOwed -= amount`

Expected invariant:

```text
Each redeem request can be claimed at most once,
and burns exactly the USDM that created exactly the corresponding USDC obligation.
```

Critical review questions:

- Can claims succeed without sufficient escrow liquidity?
- Can reclaim / fund flows desynchronize `totalOwed` and actual queued requests?
- Can pause state create stuck but economically live requests?

### 4.4 sUSDM Deposit / Mint

Users stake USDM into `sUSDM` via ERC-4626 `deposit` / `mint`.

Expected properties:

- no new protocol asset is created
- no new protocol-wide liability is created
- the wrapper exchange rate should only move because:
  - users join or leave at ERC-4626 prices
  - vault injects user-share yield

### 4.5 sUSDM Cooldown

Users exit `sUSDM` by `cooldownShares` or `cooldownAssets`, not by synchronous redeem.

State transition:

- user shares are burned immediately
- exact USDM claim amount is isolated into `sUSDMEscrow`
- `totalPendingClaims` increases
- a cooldown request is created

Security meaning:

- the unstake queue is **physically isolated**
- future yield injection should not accrue to already-cooled-down shares
- escrowed USDM should remain claimable 1:1 after cooldown

Critical review questions:

- Is there any path where `totalPendingClaims` diverges from `sUSDMEscrow` balance?
- Can rounding in `cooldownAssets` systematically leak value?
- Can users capture yield both before and after cooling down the same shares?

### 4.6 Yield Settlement

Operator calls `settle(proposedYield)`, which delegates to `MonetrixAccountant.settleDailyPnL`.

Settlement is guarded by two layers:

- Vault checks immediate EVM-side USDC availability after reserving redemption shortfall.
- Accountant checks:
  - settlement initialized
  - minimum interval elapsed
  - `proposedYield <= distributableSurplus()`
  - `proposedYield <= annualized cap`

State transition on success:

- `totalSettledYield += proposedYield`
- `proposedYield` USDC moves from Vault to `YieldEscrow`

Threats to model:

- distributable surplus computed from double-counted or stale backing
- positive mark-to-market treated as immediately distributable when EVM liquidity is unavailable
- queued redemptions not fully reserved during settle

### 4.7 Yield Distribution

Operator calls `distributeYield()`.

State transition:

- all USDC in `YieldEscrow` is pulled back to Vault
- it is split into:
  - user share
  - insurance share
  - foundation share
- for user share:
  - Vault mints USDM to itself
  - Vault injects that USDM into `sUSDM`

Critical modeling point:

```text
User yield distribution increases USDM supply.
This is safe only because the protocol simultaneously realizes and routes the matching USDC yield.
```

Special case:

- if `sUSDM.totalSupply() == 0`, user share is rerouted to foundation to avoid empty-vault yield capture by the next staker

### 4.8 Bridge and L1 Principal Management

`keeperBridge` sends excess EVM USDC to HyperCore and increments `outstandingL1Principal`.

Bridge-back paths:

- `bridgePrincipalFromL1(amount)` reduces `outstandingL1Principal` and bridges back principal
- `bridgeYieldFromL1(amount)` bridges back yield without touching principal counter

The bridge model is:

- EVM USDC may leave the Vault for L1 deployment
- the protocol must preserve enough EVM USDC for redemptions and yield operations
- `outstandingL1Principal` is an operational principal tracker, not a full solvency metric

Threats:

- principal and yield bridged back under the wrong accounting bucket
- `netBridgeable()` or `yieldShortfall()` computed incorrectly
- bridge-to-L1 leaving the vault too illiquid for queued claims

### 4.9 Hedge / BLP / HLP Positioning

Operator can move value across:

- L1 spot
- perp account
- supplied balances
- HLP vault equity

These paths do not directly change USDM supply, but they do change which precompile domains should contain backing.

Threat-model implication:

- any action that moves value between these domains is safe only if the accountant either:
  - still counts the value exactly once
  - or fail-closes until the registry/config is corrected

---

## 5. Canonical Review Invariants

### 5.1 Solvency Invariant

Primary solvency view:

```text
totalBackingSigned() - USDM.totalSupply()
```

Interpretation:

- positive: protocol economic surplus exists
- zero: exactly backed
- negative: protocol undercollateralized

This is the main invariant for protocol-wide solvency.

### 5.2 Distributable Yield Invariant

Yield must only be declared from distributable surplus:

```text
distributableSurplus()
= totalBackingSigned()
  - USDM.totalSupply()
  - RedeemEscrow.shortfall()
```

Meaning:

- queued redemptions cannot create a phantom surplus window before final burn

### 5.3 EVM Liquidity Invariant

Even if total protocol backing is positive, the Vault must not promise or route EVM-side USDC it does not actually have.

Relevant local views:

- `netBridgeable()`
- `redemptionShortfall()`
- `yieldShortfall()`

Critical distinction:

- total backing is a solvency measure
- EVM available USDC is a settlement / liveness measure

### 5.4 Redemption Isolation Invariant

For pending redeems:

- `RedeemEscrow.totalOwed` should track total live redemption obligations
- `RedeemEscrow.balance + RedeemEscrow.shortfall == RedeemEscrow.totalOwed`
- reclaim must never reduce escrow balance below `totalOwed`

### 5.5 sUSDM Isolation Invariant

For cooldowned unstakes:

- `sUSDMEscrow` balance should equal `sUSDM.totalPendingClaims`
- cooled-down claims should not continue to earn future injected yield
- claimed requests should reduce `totalPendingClaims` exactly once

### 5.6 Single-Count Backing Invariant

The same economic value must not be counted more than once across:

- `accountValueSigned`
- spot balances
- supplied balances
- HLP equity
- multisig and vault account registries

This is the highest-priority HyperCore-specific accounting invariant.

### 5.7 Registry Correctness Invariant

Supplied-asset registries and tradeable-asset config must match the actual domains used by operator actions.

Threats:

- stale supplied entries causing incorrect reads or reverts
- removed tradeable assets remaining economically live but no longer counted
- pair-asset / token-index / perp-index confusion

### 5.8 Pause / Emergency Invariant

Pause modes should only change which paths are callable, not silently break claim accounting.

Emergency actions may bypass pause, but should not bypass the economic invariants above.

---

## 6. Threat Categories to Prioritize

This section should be read together with the README's stated audit priorities. The highest-signal review areas are:

- Accountant 4-gate settle pipeline
- HyperCore precompile read semantics
- bridge + redemption coverage under bank-run conditions
- sUSDM cooldown + escrow isolation
- `ActionEncoder` / `PrecompileReader` wire-format correctness
- decimal and unit-conversion boundaries

### 6.1 Double Counting / Omitted Counting

The most important class for Monetrix.

Examples:

- supplied balances also embedded in account value
- HLP equity also embedded elsewhere
- vault and multisig registries overlapping or drifting
- whitelisted spot assets valued with the wrong domain or decimals

### 6.2 Phantom Yield

Cases where the protocol declares yield that is not truly distributable.

Examples:

- redemption-window surplus inflation
- unrealized / illiquid value treated as EVM-settleable yield
- stale backing after config or registry changes

### 6.3 Queue Desynchronization

Cases where a queue-local liability is no longer matched by its storage or escrow balance.

Examples:

- `RedeemEscrow.totalOwed` diverges from live requests
- `sUSDM.totalPendingClaims` diverges from escrowed USDM
- delete-before-transfer or transfer-before-delete sequences enable grief / replay

### 6.4 Domain-Mixup Bugs

Hyperliquid has multiple identifier spaces:

- perp index
- spot token index
- spot pair asset id

Monetrix depends on mapping these correctly.

Examples:

- using token index where pair asset id is required
- reading price for the wrong domain
- registering the wrong supplied asset after a hedge action

### 6.5 Liveness / Frozen Funds

Not every valid issue is a theft issue.

Important liveness risks:

- precompile fail-closed behavior causing permanent unusability after stale registry state
- redemptions that cannot be funded or claimed under expected operator / pause sequences
- unstake claims that become inaccessible despite escrow holding assets

---

## 7. README Areas Of Concern

### 7.1 Accountant 4-Gate Settle Pipeline

Highest priority.

The most important question is whether any path can:

- bypass Gate 1 initialization
- bypass Gate 2 minimum interval
- overstate Gate 3 `distributableSurplus()`
- bypass or miscompute Gate 4 annualized cap
- break the intended cumulative property:

```text
Sigma proposedYield <= Sigma realized surplus
```

This includes:

- wrong `totalBackingSigned()` composition
- stale supplied-asset registries
- wrong treatment of queued redemption shortfall
- incorrect interaction between settlement and EVM-side liquidity

### 7.2 HyperCore Precompile Read Semantics

Focus here:

- short-response decoding must fail closed
- EVM USDC and L1 USDC unit boundaries must be exact
- oracle / token metadata / perp metadata must be composed consistently
- signed and unsigned conversions must not wrap or silently truncate

Key files:

- `src/core/PrecompileReader.sol`
- `MonetrixAccountant._readL1Backing`

### 7.3 Bridge + Redemption Coverage Under Stress

Review `keeperBridge`, `requestRedeem`, `fundRedemptions`, and `claimRedeem` as one system rather than isolated functions.

Stress-case lens:

- what happens if EVM USDC has already been bridged away?
- what happens during many queued redemptions?
- can the system remain solvent but locally illiquid?
- can normal operator actions worsen bank-run coverage?

Vault-focused review lens:

- The highest-signal Vault question is not "can bridge move funds" in isolation.
- It is whether `bridge`, `redemption`, and `settlement` compete for the same EVM-side USDC in a way that breaks local redemption liquidity.
- In practice this means the core Vault review should prioritize two parallel tracks:
- `bridge / redemption / local liquidity`
- `settle / yield routing / reservation logic`

Concrete sequences worth stress-testing:

- `requestRedeem -> keeperBridge -> fundRedemptions -> claimRedeem`
- `requestRedeem -> settle -> claimRedeem`
- `keeperBridge -> requestRedeem -> bridgePrincipalFromL1`
- `requestRedeem -> partial funding -> settle -> claim`

### 7.4 sUSDM Cooldown + Escrow Isolation

Focus here:

- `sUSDMEscrow` should remain a perfect physical isolation layer
- cooldown should not alter exchange rate except through intended rounding rules
- claims should be single-use and exactly matched to escrowed USDM
- injected yield should accrue only to still-active shares

### 7.5 `ActionEncoder` / `PrecompileReader` Libraries

Focus here:

- wire-format correctness for HyperCore actions
- boundary behavior of `uint64` amounts
- field-order correctness
- pair-asset / token-index / perp-index mixups

### 7.6 Decimal and Unit-Conversion Boundaries

Focus here:

- `TokenMath.usdcEvmToL1Wei`
- `TokenMath.usdcL1WeiToEvm`
- `TokenMath.spotNotionalUsdcFromPerpPx`
- any perp/spot wei conversion used across read/write boundaries

The main failure mode is not only bad arithmetic. It is **counting the right economic object in the wrong unit**.

---

## 8. Main Invariants

### INV-1 Peg Solvency (Soft Invariant)

Protocol-level backing is:

```text
totalBackingSigned() =
    USDC.balanceOf(Vault)
  + USDC.balanceOf(RedeemEscrow)
  + Sigma L1 spot USDC
  + Sigma L1 spot x oraclePx               (whitelist)
  + Sigma 0x811 supplied USDC / spot x px  (registered slots)
  + perp accountValue (signed)
  + HLP equity
```

Under normal operation:

```text
totalBackingSigned() >= int256(USDM.totalSupply())
```

This is a soft invariant. Deposit does not gate on backing; settlement indirectly enforces solvency discipline through `distributableSurplus() > 0` and the gate checks. Temporary violations can still occur under stress, negative funding, or read anomalies.

Recovery path:

- `InsuranceFund.withdraw -> Vault` via Governor

### INV-2 sUSDM Exchange Rate Is Monotonic

Under normal operation:

```text
rate(t) = totalAssets(t) / totalSupply(t)
```

Expected behavior:

- rate increases only on `injectYield`
- `cooldownShares` and `cooldownAssets` should leave rate unchanged modulo intended ERC-4626 rounding
- `claimUnstake` should not change the active sUSDM rate because assets are released from `sUSDMEscrow`, not from the live sUSDM asset pool

### INV-3 Redemption Accounting Correctness

`RedeemEscrow.totalOwed` should precisely track outstanding unclaimed redemption commitments.

Expected transitions:

- `requestRedeem -> totalOwed += usdmAmount`
- `claimRedeem -> totalOwed -= usdmAmount`

There should be no other economic path that mutates redemption obligations.

### INV-3a No Silent Haircut

`RedeemEscrow.payOut` reverts unless escrow balance covers the full amount. Claimants should never receive less than owed.

### INV-3b Reclaim Cannot Erode Obligations

`RedeemEscrow.reclaimTo` must never reduce escrow below `totalOwed`.

### INV-4 sUSDM Unstake Balance Equals Commitments

Expected local invariant:

```text
USDM.balanceOf(sUSDMEscrow) == sUSDM.totalPendingClaims
```

`cooldown*` must increase both sides together and `claimUnstake` must decrease both sides together.

### INV-5 Gate 1 Initialization

`settleDailyPnL` must revert when `lastSettlementTime == 0`. Initialization should happen exactly once via `initializeSettlement()`.

### INV-6 Gate 2 Minimum Interval

Settlement must satisfy:

```text
block.timestamp >= lastSettlementTime + minSettlementInterval
```

### INV-7 Gate 3 Distributable Cap

Settlement must satisfy:

```text
proposedYield <= distributableSurplus()
```

where:

```text
distributableSurplus() = surplus() - shortfall()
surplus() = totalBackingSigned() - int256(USDM.totalSupply())
```

### INV-8 Gate 4 Annualized APR Cap

Settlement must satisfy:

```text
proposedYield <= USDM.totalSupply() * maxAnnualYieldBps * dt / (10000 * 1 year)
```

with:

- `maxAnnualYieldBps` Governor-settable
- bounded by `MAX_ANNUAL_YIELD_BPS_CAP`
- initial configured value `1200`

### INV-9 Cumulative Yield Bounded By Cumulative Surplus

Under trusted operator reporting and correct gate enforcement:

```text
Sigma proposedYield across all settles <= Sigma realized surplus across the same window
```

`totalSettledYield` is the on-chain cumulative counter, not the full proof by itself.

### INV-10 USDM Mint/Burn Only By Vault

`USDM.mint` and `USDM.burn` should remain `onlyVault`.

### INV-11 `sUSDM.injectYield` Only By Vault

No external or operator account should be able to inject yield directly.

### INV-12 Escrow Fund Movements Are Properly Gated

Expected gating:

- `RedeemEscrow.{addObligation, payOut, reclaimTo}` -> `onlyVault`
- `YieldEscrow.pullForDistribution` -> `onlyVault`
- `sUSDMEscrow.{deposit, release}` -> `onlySUSDM`

### INV-13 Accountant Privileged Surface Only By Vault

Expected gating:

- `Accountant.settleDailyPnL` -> `onlyVault`
- `Accountant.notifyVaultSupply` -> `onlyVault`

---

## 9. Trusted Roles

### DEFAULT_ADMIN

- grants / revokes all roles
- authorizes ACL upgrade
- timelocked

### UPGRADER

- authorizes UUPS upgrades for all core proxies
- timelocked

### GOVERNOR

- owns config / accountant / vault setters
- owns `InsuranceFund.withdraw`
- owns Vault emergency paths including `emergencyRawAction` and `emergencyBridgePrincipalFromL1`
- these emergency paths intentionally bypass both pause flags

### OPERATOR

- controls bridge, hedge, HLP, BLP, yield settlement/distribution, redemption funding, and reclaim routing
- is code-bounded to pre-set protocol destinations
- cannot arbitrarily route protocol funds to any arbitrary address

### GUARDIAN

- controls the two pause switches
- has no direct fund authority

### Vault Contract

- is the only direct caller for USDM mint/burn, `sUSDM.injectYield`, escrow movement hot paths, and privileged accountant entrypoints

---

## 10. Function-by-Function Review Focus

### `MonetrixVault.deposit`

- 1:1 minting against actual USDC receipt
- deposit caps / max TVL enforcement

### `MonetrixVault.requestRedeem`

- obligation creation before burn
- queue integrity
- phantom-yield implications

### `MonetrixVault.claimRedeem`

- single-use claim semantics
- exact burn / payout matching
- escrow liquidity dependence

### `MonetrixVault.keeperBridge`

- reservation of redemption liquidity and bridge retention
- correct recipient domain (`Vault` vs `Multisig`)
- principal tracker updates

### `MonetrixVault.bridgePrincipalFromL1` / `bridgeYieldFromL1`

- principal vs yield separation
- L1 availability checks
- PM-enabled supplied-USDC handling

### `MonetrixVault.settle`

- distributable vs available EVM USDC
- interaction with queued redemption shortfall
- all-or-nothing movement into `YieldEscrow`

### `MonetrixVault.distributeYield`

- split correctness
- empty-sUSDM reroute behavior
- USDM minting only against matching realized USDC

### `MonetrixVault.fundRedemptions` / `reclaimFromRedeemEscrow`

- preserving claim liquidity
- inability to underfund existing obligations

### `MonetrixAccountant.totalBackingSigned`

- exact composition of backing
- multisig inclusion
- no double counting
- fail-closed behavior under precompile errors

### `MonetrixAccountant.distributableSurplus`

- redemption-window adjustment
- no overstatement of yieldable surplus

### `MonetrixAccountant.notifyVaultSupply` / `addMultisigSupplyToken` / `removeSuppliedEntry`

- registry freshness
- whether removal can create hidden assets or only conservative undercounting

### `sUSDM.cooldownShares` / `cooldownAssets` / `claimUnstake`

- escrow isolation
- fair exchange-rate handling
- no double-claim / stale-claim behavior

---

## 11. Out-of-Scope or Lower-Priority Ideas

Usually not the best primary review targets:

- "trusted operator refuses to act"
- "governor sets a bad but syntactically allowed parameter"
- "upgrader upgrades to malicious code"
- generic ERC20 approval race discussion where the code uses fixed system actors and direct flows

These can still matter if they expose a genuine contract invariant failure under normal intended usage.

---

## 12. Bottom-Line Review Lens

The best way to review Monetrix is to ask this on every path:

```text
What economic value moved?
Which accounting domain lost it?
Which accounting domain gained it?
Which liability changed?
Can the accountant now see that state exactly once?
```

If any path allows value to:

- disappear from backing without liability reduction,
- appear in backing twice,
- become distributable before it is truly available,
- or escape a queue / escrow invariant,

then the threat model has identified a real audit target.

---

## 13. Current Review Hypotheses

This section tracks live hypotheses during review. Hypotheses should be promoted to issue candidates only after a runnable PoC demonstrates concrete impact.

### H-01 Redemption Queue Does Not Create Phantom Surplus If USDM Is Not Burned Until Claim

Current understanding:

- `requestRedeem` transfers user USDM into the Vault
- `RedeemEscrow.totalOwed` increases
- `USDM.totalSupply()` remains unchanged
- `claimRedeem` later burns Vault-held USDM and pays USDC

Implication:

Because supply is not reduced at request time, the queued redemption liability remains represented in `USDM.totalSupply()`.

Therefore the current formula may be directionally correct:

```text
surplus = totalBackingSigned - USDM.totalSupply
distributableSurplus = surplus - shortfall
```

The remaining risk is not "totalOwed must always be subtracted."

The remaining risk is whether shortfall-only treatment fails under some interleaving of:

- request redemption
- partial funding
- settlement
- bridge
- claim

Review status:

- not rejected completely
- lower priority than before
- needs a precise PoC showing a concrete sequence where queued obligations are still under-reserved despite supply remaining unchanged

### H-02 Funded Redemption Escrow USDC Is Counted As Backing By Design

Current understanding:

- `RedeemEscrow` USDC is counted in `totalBackingSigned()`

This appears intentional because queued redemption USDM remains in supply until claim. Escrowed USDC backs that still-existing USDM liability.

Valid concern:

- if any path burns USDM before the matching escrow payout
- or reduces supply without reducing `totalOwed`

then the same escrow-accounting choice becomes dangerous.

Review action:

- search all `usdm.burn` call paths and confirm they occur only during claim or otherwise intended Vault-only flows

### H-03 HyperCore Domain Independence Remains The Main Unresolved Accounting Question

The most important unresolved accounting question is whether the following domains are economically independent:

- `accountValueSigned`
- spot USDC
- spot hedge token balances
- supplied balances
- HLP equity

If any one of these already includes another, then `totalBackingSigned()` overstates backing.

Review action:

- inspect fork tests
- inspect HyperCore precompile docs if available
- compare mock assumptions with real precompile semantics
- build a PoC only if the overlap represents a possible real HyperCore state

### H-04 Supplied-Asset Registry Freshness May Cause Stale Accounting Or Fail-Closed Liveness

Operator actions can register supplied assets in Accountant.

Risk cases:

- supplied asset is withdrawn but registry remains
- supplied asset is no longer whitelisted but registry still tries to read it
- supplied token / perp mapping changes after registration
- stale registry causes `totalBackingSigned()` to revert or misvalue backing

This is not automatically invalid because Operator is trusted. The issue would be valid only if normal protocol flows can leave stale state that breaks user-facing functions, settlement, or redemption liveness without a reasonable recovery path.

### H-05 `multisigVault` Inclusion May Count Non-Protocol Assets As Backing

When enabled, `totalBackingSigned()` includes the L1 backing of `multisigVault`.

Potential issue shape:

- `multisigVault` contains assets not economically pledged to USDM
- Accountant counts them as USDM backing
- yield settlement succeeds because unrelated assets are included

Trust caveat:

- if this is purely a Governor configuration issue, it is likely invalid
- it becomes more interesting only if the protocol design expects `multisigVault` to be used for multiple purposes or if no invariant prevents accidental inclusion of unrelated HyperCore balances

### H-06 Near-Zero `sUSDM` Supply Yield Capture Is Probably Design Behavior Unless Timing Creates User Harm

`distributeYield()` reroutes user yield only when:

```text
sUSDM.totalSupply() == 0
```

If supply is tiny but nonzero, current holders capture all injected user yield.

This is likely normal ERC-4626-style ownership-at-injection behavior. It becomes interesting only if:

- yield economically belongs to a previous accrual period's stakers
- an attacker can cheaply remain as a dust holder
- other users are predictably forced or strongly incentivized to exit before distribution
- documentation promises time-weighted accrual rather than pro-rata ownership at injection time


 ## Monetrix 资金部署路径对比

  | 路径 | 代码入口 | 资金去了哪里 | 收益来源 | 主要风险 | Accountant 怎么记 |
  |---|---|---|---|---|---|
  | hedge | executeHedge / closeHedge / repairHedge | Vault 自己在 HyperCore 上持有 spot + perp 仓位 | funding / basis / carry / 对冲后净收益 | 双腿非原子、partial fill、repair 扩仓、domain
  mixup、double count | 分散记入 accountValueSigned、spot、supplied、spot token notionals |
  | HLP | depositToHLP / withdrawFromHLP | 资金存进 HLP_VAULT | HLP vault 的池子收益 / PnL | equity 波动、提款锁仓、可能和别的域重复计数 | 单独记入 vaultEquity(HLP_VAULT) |
  | BLP | supplyToBlp / withdrawFromBlp | 资金进入 0x811 supplied / borrow-lend pool | 出借 / supplied 收益 | stale registry、supplied 读语义错误、和 account value 重叠 | 通过 supplied
  registry 记入 suppliedUsdcEvm 或 suppliedNotionalUsdcFromPerp |
