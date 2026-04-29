# Monetrix Issue Candidates

## Active Candidates

---

## C-01: Redemption obligations and shortfall-only surplus deduction

### Status

Downgraded from highest-priority to conditional.

### Updated understanding

`requestRedeem` transfers USDM from the user to the Vault and creates a redemption obligation, but does not burn USDM immediately.

Therefore, the redemption liability remains represented in `USDM.totalSupply()` until `claimRedeem`.

This weakens the original concern that `RedeemEscrow.totalOwed` must always be subtracted from `distributableSurplus()`.

### Remaining concern

The issue may still exist if a subtler interleaving causes shortfall-only reservation to under-protect redemption liquidity, for example:

- settlement after partial redemption funding
- bridge after redemption request but before funding
- claim after settlement drains local USDC
- pause or emergency state preventing funding but allowing other value movement
- mismatch between Vault-held USDM burn timing and escrow payout timing

### Required PoC

A valid PoC must show more than:

```text
totalOwed > 0 and shortfall == 0
```

It must show concrete harm such as:

- claim failure caused by settlement or bridge formula
- yield distributed from value that should have remained reserved
- remaining system undercollateralized after claim
- or user funds stuck due to accounting or liveness mismatch

---

## C-01A: Bridge / redemption / settlement interleavings may break local EVM liquidity despite protocol solvency

### Status

Active / high-priority Vault candidate.

### Core concern

For `MonetrixVault.sol`, the highest-signal review lens is not any single function in isolation.

The real question is whether these two parallel tracks compete unsafely for the same EVM-side USDC:

- `bridge / redemption / local liquidity`
- `settle / yield routing / reservation logic`

The protocol may remain economically solvent on `totalBackingSigned()` while still becoming locally illiquid for user redemption.

### Candidate sequences

- `requestRedeem -> keeperBridge -> fundRedemptions -> claimRedeem`
- `requestRedeem -> settle -> claimRedeem`
- `requestRedeem -> partial funding -> settle -> claim`
- `keeperBridge -> requestRedeem -> bridgePrincipalFromL1`
- `bridgeYieldFromL1 -> settle -> distributeYield`

### Valid issue shape

This is a real issue only if a normal allowed sequence causes:

- insufficient EVM USDC for redemption funding or claim
- yield settlement from value that should have remained effectively reserved for redemption recovery
- or a bounded-recovery assumption to fail in a user-harmful way

### Required PoC

A valid PoC should show:

- protocol-wide backing remains nontrivially positive or apparently healthy
- but a reachable interleaving still causes redemption failure, prolonged stuck funds, or improper yield confirmation
- and the failure is due to reservation / routing logic rather than pure operator refusal to act

---

## C-01B: `multisigVault` principal can count as backing while remaining unavailable to the normal redemption recovery path

### Status

Active / high-priority Vault liveness candidate.

### Core concern

`keeperBridge(BridgeTarget.Multisig)` can bridge principal to the `multisigVault` L1 account while incrementing the single global `outstandingL1Principal` counter.

At the same time:

- `MonetrixAccountant.totalBackingSigned()` includes `multisigVault` L1 balances as protocol backing
- but `bridgePrincipalFromL1()` and `_sendL1Bridge()` only source bridge-back liquidity from the Vault contract's own L1 account at `address(this)`

This creates a reachable state where:

- protocol-wide backing appears healthy
- `outstandingL1Principal` claims principal is recoverable
- but the normal Vault recovery path cannot actually bridge that principal back for redemptions

### Reachable sequence

- user deposits USDC
- operator calls `keeperBridge(Multisig)`
- bridged principal sits on `multisigVault` L1 account
- user later calls `requestRedeem`
- `redemptionShortfall()` becomes positive
- `bridgePrincipalFromL1(shortfall)` reverts because Vault's own L1 account has no USDC even though `multisigVault` does

### Impact hypothesis

This is not pure insolvency.

The impact is:

- redemption recovery path is broken under a normal permitted workflow
- users can face stuck or delayed redemption despite apparent protocol solvency
- the single `outstandingL1Principal` counter overstates what the Vault-side bridge path can actually mobilize

### Why this is not just "trusted multisig"

The issue is not "Governor pointed `multisigVault` at an arbitrary address."

The issue is narrower and stronger:

- even if `multisigVault` is a legitimate protocol address
- and even if its balances truly belong to the protocol

the normal bridge-back logic still cannot recover those funds through `bridgePrincipalFromL1()`.

### Required PoC

A valid PoC should show:

- principal is bridged to `multisigVault` through the intended path
- Accountant counts that value in backing
- redemption shortfall becomes positive
- normal `bridgePrincipalFromL1()` recovery reverts because the Vault L1 account lacks USDC
- user-facing redemption remains underfunded unless some off-path/manual recovery happens

---

## C-02: `totalBackingSigned()` may double-count independent HyperCore domains

### Status

Active / highest-priority accounting hypothesis.

### Core concern

`MonetrixAccountant._readL1Backing()` adds multiple HyperCore domains into backing:

- `accountValueSigned`
- spot USDC
- supplied balances
- whitelisted spot token notionals
- HLP equity

This is safe only if these domains are economically independent.

### Valid issue shape

The issue exists only if some real HyperCore state allows one of these values to already embed another, for example:

- `accountValueSigned` already reflects spot collateral
- supplied balances are already represented inside margin/account value
- HLP equity is reflected in some other domain being summed

### Required PoC

A valid PoC must show:

- a plausible HyperCore state
- the same economic value being counted twice by `totalBackingSigned()`
- and concrete downstream harm such as surplus overstatement, successful over-settlement, or false solvency

Mock-only overlap is not enough unless it matches real precompile semantics.

---

## C-03: Supplied-asset registry stale state may break accounting or liveness

### Status

Active / medium-priority conditional candidate.

### Core concern

Accountant backing reads depend on the supplied-asset registries:

- `notifyVaultSupply`
- `addMultisigSupplyToken`
- `removeSuppliedEntry`

Normal operator flows can register entries, but some close / withdraw paths do not automatically remove them.

### Valid issue shape

The issue exists only if stale registry state can cause:

- `totalBackingSigned()` to revert in reachable normal operation
- backing to be materially overcounted or misvalued
- settlement or redemption liveness failure without a reasonable operator recovery path

### Required PoC

A valid PoC must show more than "registry becomes stale."

It must show one of:

- stale state causes accounting overstatement
- stale state causes fail-closed behavior that blocks user-relevant protocol operations
- stale state can be reached through normal allowed workflows, not only malicious operator misuse

---

## C-04: `repairHedge` may permit exposure expansion rather than bounded repair

### Status

Active / medium-priority hedge hypothesis.

### Core concern

`repairHedge` is a single-leg action whose parameters are keeper-controlled:

- `isPerp`
- `isBuy`
- `reduceOnly`
- `size`
- `price`

The contract validates asset domain, but does not itself enforce that the action strictly reduces residual exposure.

### Valid issue shape

This becomes a real issue only if:

- a normal repair flow can create materially larger net exposure than the residual being repaired
- and that expanded exposure can break accounting, solvency assumptions, or user-facing safety

If this is merely "trusted operator can misuse repairHedge", it is probably invalid.

### Required PoC

A valid PoC must show:

- a reachable position state
- a `repairHedge` call sequence accepted by the contract
- resulting net exposure materially larger or directionally wrong relative to intended repair
- concrete impact beyond discretionary operator trading behavior

---

## C-05: PM autosupply registration may diverge from real `0x811` state

### Status

Active / medium-priority integration hypothesis.

### Core concern

Under `pmEnabled`, `executeHedge` registers a supplied token in Accountant on the assumption that acquired spot will auto-supply into `0x811`.

If real HyperCore behavior differs, registry state may get ahead of actual supplied state.

### Valid issue shape

The issue exists only if this divergence can cause:

- fail-closed revert in backing reads
- material overcount / undercount
- or reachable settlement / liveness failure

### Required PoC

A valid PoC must show:

- a realistic PM-enabled execution path
- actual divergence between registry state and real supplied state
- and a concrete accounting or liveness impact

---

## C-06: `multisigVault` backing inclusion may admit unrelated assets into USDM solvency

### Status

Active / low-to-medium priority conditional candidate.

### Core concern

When enabled, `totalBackingSigned()` includes the L1 backing of `multisigVault`.

### Valid issue shape

This is interesting only if:

- protocol design allows `multisigVault` to hold assets not exclusively pledged to USDM
- and no invariant prevents those balances from being treated as backing for settlement / solvency

If this reduces to "Governor set the wrong multisig address", it is likely not a valid issue.

### Required PoC

A valid PoC must show:

- reachable inclusion of economically unrelated assets
- those assets being counted in `totalBackingSigned()`
- and concrete downstream impact such as excess yield settlement or false solvency
