# Monetrix Invariants

## 1. Reading Guide

Monetrix has two different classes of invariants:

- protocol-wide economic solvency
- local EVM-side liquidity and routing safety

These are not the same.

A state can satisfy:

```text
totalBackingSigned() >= USDM.totalSupply()
```

while still failing to satisfy timely redemption on EVM because value is trapped in:

- L1 spot balances
- supplied balances
- HLP equity
- multisig-held balances
- or otherwise non-immediately-available domains

The most important review lens for `MonetrixVault.sol` is therefore:

- `bridge / redemption / local liquidity`
- `settle / yield routing / reservation logic`

Many valid findings in Vault are likely to be reservation or liveness failures rather than direct solvency failures.

---

## 2. Protocol-Level Solvency Invariants

### INV-1 Composite backing covers USDM liabilities under normal operation

Protocol-level soft solvency is:

```text
totalBackingSigned() >= int256(USDM.totalSupply())
```

where:

```text
totalBackingSigned() =
    USDC.balanceOf(Vault)
  + USDC.balanceOf(RedeemEscrow)
  + Sigma L1 spot USDC
  + Sigma L1 spot token notionals
  + Sigma supplied USDC / supplied token notionals
  + perp accountValueSigned
  + HLP equity
  + optional multisigVault L1 backing
```

Notes:

- This is a soft invariant, not a hard runtime guard on deposit.
- Temporary violations may occur under stress, negative funding, or read anomalies.
- `YieldEscrow` and `InsuranceFund` are excluded from backing by design.

### INV-2 No double counting across HyperCore accounting domains

The same economic value must not be counted twice across:

- `accountValueSigned`
- spot USDC
- supplied USDC / supplied token balances
- whitelisted spot hedge token balances
- HLP equity
- Vault-side and `multisigVault`-side L1 registries

This is the highest-priority accountant invariant.

### INV-3 YieldEscrow is excluded from protocol backing

Once USDC has been moved into `YieldEscrow`, it must no longer support:

- protocol solvency claims for undecided yield
- future yield settlement
- generic Vault operating balance assumptions

Intended consequence:

```text
settled yield is isolated,
not still counted as general-purpose backing
```

### INV-4 InsuranceFund is ring-fenced reserve, not user backing

USDC held in `InsuranceFund` is excluded from `totalBackingSigned()` and should not be treated as immediately supporting `USDM.totalSupply()` until explicitly withdrawn back into protocol circulation.

---

## 3. Redemption Invariants

### INV-5 Redemption request does not reduce USDM supply

`requestRedeem`:

- transfers USDM from user to Vault
- increases `RedeemEscrow.totalOwed`
- records a request
- does **not** burn USDM

Therefore:

```text
queued redemption liability remains represented in USDM.totalSupply()
until claimRedeem
```

This is critical for evaluating `surplus()` and `distributableSurplus()`.

### INV-6 Redemption claim burns only previously-custodied Vault USDM

`claimRedeem`:

- consumes an existing redeem request
- burns USDM from Vault-held balance
- pays USDC from `RedeemEscrow`

Therefore:

- current user wallet balance is irrelevant at claim time
- the economic dependency is on request state plus escrow liquidity

### INV-7 Redemption obligation accounting is symmetric

Expected transitions:

```text
requestRedeem -> totalOwed += usdmAmount
claimRedeem   -> totalOwed -= usdmAmount
```

No other path should mutate redemption obligations in a way that breaks this symmetry.

### INV-8 No silent haircut on redemption payout

`RedeemEscrow.payOut` must revert rather than partially pay if escrow balance is insufficient.

This means:

- redemption claims may be delayed
- but they should not be silently haircut

### INV-9 Reclaim cannot erode funded obligations

`RedeemEscrow.reclaimTo` must not reduce escrow balance below `totalOwed`.

Formally:

```text
RedeemEscrow.balance() >= amount + totalOwed
```

must hold for reclaim to succeed.

### INV-10 RedeemEscrow shortfall identity

At all times:

```text
RedeemEscrow.balance() + RedeemEscrow.shortfall() == RedeemEscrow.totalOwed
```

This is the key local invariant that connects redemption queue state to liquidity needs.

---

## 4. sUSDM / Cooldown Invariants

### INV-11 sUSDM exchange rate is non-decreasing under normal operation

For active shares:

```text
rate = totalAssets() / totalSupply()
```

Expected behavior:

- increases on `injectYield`
- remains unchanged modulo rounding on `cooldownShares`
- remains unchanged modulo rounding on `cooldownAssets`
- is unaffected by `claimUnstake`, which releases from `sUSDMEscrow`, not live sUSDM assets

### INV-12 Unstake queue is physically isolated

During cooldown:

- shares are burned immediately
- exact USDM claim is transferred into `sUSDMEscrow`
- `totalPendingClaims` increases by the same amount

This means cooled-down claimants should not continue earning future injected yield.

### INV-13 sUSDMEscrow balance equals pending unstake commitments

Expected local invariant:

```text
USDM.balanceOf(sUSDMEscrow) == sUSDM.totalPendingClaims
```

This should be maintained by:

- `cooldownShares`
- `cooldownAssets`
- `claimUnstake`

### INV-14 Empty-vault yield capture must be blocked

User-share yield injection into `sUSDM` must not be allowed when:

```text
sUSDM.totalSupply() == 0
```

Current design consequence:

- `sUSDM.injectYield` itself requires nonzero supply
- `distributeYield()` reroutes would-be user share to foundation if supply is zero

---

## 5. Settlement And Yield Invariants

### INV-15 Settlement is all-or-nothing

For a successful `settle(proposedYield)`:

- Accountant accepts the yield through `settleDailyPnL`
- exactly `proposedYield` USDC moves from Vault to `YieldEscrow`

If any step fails, no partial settlement state should remain.

### INV-16 Gate 1: settlement must be initialized

`settleDailyPnL` must revert if:

```text
lastSettlementTime == 0
```

Initialization should happen exactly once via `initializeSettlement()`.

### INV-17 Gate 2: minimum interval must elapse

Settlement must satisfy:

```text
block.timestamp >= lastSettlementTime + minSettlementInterval
```

### INV-18 Gate 3: proposed yield must not exceed distributable surplus

Settlement must satisfy:

```text
proposedYield <= distributableSurplus()
```

where:

```text
surplus() = totalBackingSigned() - int256(USDM.totalSupply())
distributableSurplus() = surplus() - int256(RedeemEscrow.shortfall())
```

Critical interpretation:

- because `requestRedeem` does not burn immediately, queued obligations remain inside `USDM.totalSupply()`
- the remaining local reservation adjustment is the still-unfunded `shortfall`

### INV-19 Gate 4: proposed yield must not exceed annualized cap

Settlement must satisfy:

```text
proposedYield <= USDM.totalSupply() * maxAnnualYieldBps * dt / (10000 * 1 year)
```

This is the on-chain rate limiter on keeper-reported yield.

### INV-20 Cumulative settled yield should remain bounded by realized surplus

Under correct accounting and trusted operator reporting:

```text
Sigma proposedYield across settles <= Sigma realized distributable surplus
```

`totalSettledYield` is only the cumulative counter; it is not by itself proof that this invariant holds.

### INV-21 Yield settlement must respect local redemption liquidity

Vault-level `settle()` must not use EVM-side USDC that is still needed to cover current redemption shortfall.

Current formula:

```text
available = VaultUSDC - RedeemEscrow.shortfall()
require(available >= proposedYield)
```

Interpretation:

- pending redemption shortfall has priority over yield settlement
- `bridgeRetentionAmount` is not treated as a hard solvency reservation in `settle()`

### INV-22 Yield distribution only spends previously settled yield

`distributeYield()` must route only the USDC currently isolated in `YieldEscrow`.

It should not:

- invent fresh yield
- rely on generic Vault balance
- or re-count already-distributed yield

### INV-23 User-share distribution is backed by matching settled USDC

When distributing user yield:

- Vault pulls settled USDC from `YieldEscrow`
- Vault mints matching USDM to itself
- Vault injects that USDM into `sUSDM`

This is safe only if the corresponding USDC yield was already realized and isolated at settlement time.

---

## 6. Local EVM Liquidity Invariants

### INV-24 Protocol solvency and local redeemability are distinct

A protocol state may satisfy:

```text
totalBackingSigned() >= USDM.totalSupply()
```

while still failing user redemption because EVM-side USDC is insufficient.

This distinction must be preserved in review and PoC design.

### INV-25 netBridgeable only uses truly excess EVM USDC

Expected formula:

```text
netBridgeable = VaultUSDC - RedeemEscrow.shortfall() - bridgeRetentionAmount
```

clamped at zero.

Interpretation:

- redemption shortfall is user-facing reservation
- `bridgeRetentionAmount` is operator working balance reservation

### INV-26 Principal bridge-back is constrained by both need and accounting

`bridgePrincipalFromL1(amount)` must satisfy:

```text
amount <= redemptionShortfall()
amount <= outstandingL1Principal
```

Meaning:

- principal bridge-back is bounded by current redemption need
- and by protocol-side principal bookkeeping

### INV-27 Yield bridge-back is bounded by yield shortfall

`bridgeYieldFromL1(amount)` must satisfy:

```text
amount <= yieldShortfall()
```

This is intended to keep yield bridge-back separate from principal accounting.

### INV-28 L1 bridge-back feasibility depends on actual L1 USDC, not total backing

`_sendL1Bridge(amount)` should succeed only if L1-accessible USDC is actually available:

- spot USDC
- plus supplied USDC when PM is enabled

This is a local bridge feasibility invariant, not a protocol solvency invariant.

### INV-29 multisigVault backing inclusion does not imply immediate redeem liquidity

Even if `multisigVault` balances are counted inside `totalBackingSigned()`, that does not automatically mean Vault can immediately satisfy EVM-side redemption needs from them.

This gap is a major source of possible liveness issues.

---

## 7. Cross-Function Interleaving Invariants

### INV-30 `requestRedeem -> settle -> claimRedeem` must not create phantom yield or stuck claims

Required property:

- queued redemption remains represented in `USDM.totalSupply()`
- still-unfunded portion remains represented by `shortfall`
- settlement must not consume EVM-side USDC that is effectively needed for claim recovery

### INV-31 `keeperBridge -> requestRedeem -> bridgePrincipalFromL1` must preserve bounded recovery

If normal bridging has moved excess EVM USDC to L1, a later redeem request should still have a bounded path to recovery through:

- `fundRedemptions`
- `bridgePrincipalFromL1`

The valid issue shape here is not operator refusal, but formula or routing logic that breaks this recovery path.

### INV-32 `requestRedeem -> partial funding -> settle -> claim` must not over-confirm yield

Partial funding of `RedeemEscrow` should not permit:

- premature yield settlement from effectively reserved cash
- or subsequent claim failure caused by prior settlement

### INV-33 `bridgeYieldFromL1 -> settle -> distributeYield` must not count the same realized value twice

If yield is first bridged from L1 and then settled / distributed, the same economic value must not appear as:

- current Vault USDC
- and still part of unconsumed L1 backing
- and again as distributable yield

### INV-34 `executeHedge / supplyToBlp / Accountant read` must preserve registry correctness

If operator actions change which domain holds value:

- spot
- supplied
- perp
- HLP

then Accountant registries and config must remain aligned so that backing is:

- counted exactly once
- not silently omitted
- or fail-closed only in a way that has a reasonable recovery path

---

## 8. Access Control Invariants

### INV-35 USDM mint/burn is Vault-only

`USDM.mint` and `USDM.burn` must remain callable only by Vault.

### INV-36 sUSDM yield injection is Vault-only

`sUSDM.injectYield` must remain callable only by Vault.

### INV-37 Escrow hot paths are tightly gated

Expected gating:

- `RedeemEscrow.addObligation` -> Vault only
- `RedeemEscrow.payOut` -> Vault only
- `RedeemEscrow.reclaimTo` -> Vault only
- `YieldEscrow.pullForDistribution` -> Vault only
- `sUSDMEscrow.deposit` -> sUSDM only
- `sUSDMEscrow.release` -> sUSDM only

### INV-38 Accountant privileged entrypoints are Vault-only

Expected gating:

- `settleDailyPnL` -> Vault only
- `notifyVaultSupply` -> Vault only

### INV-39 Pause changes callable surface, not accounting truth

Pause modes may change liveness, but should not create silent accounting divergence.

Specifically:

- `paused` and `operatorPaused` protect different surfaces
- emergency paths may bypass pause
- bypassing pause should not imply bypassing economic invariants

---

## 9. Review Priorities Encoded As Invariants

The most valuable invariants to actively falsify with tests or PoCs are:

1. `INV-2`: no double counting across HyperCore domains
2. `INV-18`: `distributableSurplus()` does not overstate settleable yield
3. `INV-21`: `settle()` does not consume USDC needed for redemption recovery
4. `INV-24`: solvency does not imply redeemability
5. `INV-30` to `INV-33`: dangerous interleavings across bridge, redemption, and settlement

If one of these breaks, the protocol may still look superficially healthy while user-facing safety has already failed.
