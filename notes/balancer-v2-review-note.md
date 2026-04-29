# Balancer V2 Review Note

## 1. Review Goal

This review studied selected Balancer V2 mechanisms from a DeFi financial-security perspective.

The focus was on:

- Vault settlement accounting
- batch swap netting
- BPT share accounting
- Asset Manager cash/managed balances
- protocol fee realization
- read-only reentrancy and unsafe derived views

The goal was not to fully audit the entire Balancer V2 monorepo. The goal was to build a clear security model and targeted tests around Balancer V2's highest-value accounting boundaries.

---

## 2. Core Mental Model

Balancer V2 separates custody, math, and LP claims.

- Vault holds and settles assets.
- Pool computes swap/join/exit math.
- Pool owns BPT mint/burn logic.
- `BalanceAllocation` defines pool-token accounting.
- Asset Manager moves value between Vault cash and external managed claims.
- Protocol fee debt can exist as unminted BPT.
- Derived views may be unsafe during inconsistent Vault context.

The central model is:

    Pool calculates. Vault settles. Vault records.

This makes Balancer V2 architecturally cleaner than many complex DeFi protocols, even though its accounting surface is deep.

---

## 3. Main Accounting Invariants

### 3.1 Vault custody

For each supported token, the Vault's actual token balance should cover Vault-custodied liabilities, including:

- pool cash balances
- user internal balances

This excludes explicitly managed balances and other protocol-defined non-custodied claims.

Managed balances are economic claims of a pool, but they are not immediately available Vault cash.

---

### 3.2 Pool-token balance identity

For each pool-token:

    total = cash + managed

Where:

- `cash` = token amount actually held by the Vault
- `managed` = token amount withdrawn by the Asset Manager
- `total` = pool's economic balance for that token

`cash` and `managed` must not contaminate unrelated pools or unrelated tokens.

---

### 3.3 Settlement conservation

For swaps, joins, exits, and flash loans:

    Vault-side balance delta
        should equal
    user settlement + protocol fee settlement

For exits:

    finalCash = previousCash - amountOut - protocolFeeAmount

For joins:

    finalCash = previousCash + amountIn - protocolFeeAmount

If protocol fee exceeds nominal token input, cash can decrease even during a join.

---

### 3.4 BPT coherence

BPT mint/burn must be consistent with invariant growth/shrink after applying fee rules and protocol fee realization.

Important distinction:

    totalSupply() = currently minted BPT
    actualSupply = totalSupply + pending protocol fee BPT

Most BPT valuation and join/exit math should reason about effective supply, not only raw ERC20 `totalSupply()`.

---

### 3.5 Batch netting

For `batchSwap`:

    assetDeltas[i] > 0  => Vault receives asset i
    assetDeltas[i] < 0  => Vault sends asset i

Each swap step contributes:

    assetDeltas[assetInIndex]  += amountIn
    assetDeltas[assetOutIndex] -= amountOut

Intermediate assets may net to zero and should not require external settlement.

---

### 3.6 Read-only safety

Derived views such as:

- rate
- supply
- invariant
- BPT valuation
- effective supply

must not be treated as safe oracle inputs during inconsistent Vault context.

A view function is not automatically safe if it derives value from Vault balances and pool-side state that may temporarily diverge during join, exit, or swap execution.

---

## 4. Key Surfaces Reviewed

### 4.1 Vault settlement kernel

Relevant files:

- `pkg/vault/contracts/PoolBalances.sol`
- `pkg/vault/contracts/Swaps.sol`
- `pkg/vault/contracts/FlashLoans.sol`

Main risks:

- pool hook returns economically inconsistent amounts
- transfer/final-balance ordering mismatch
- protocol fee realization timing
- token ordering / asset ordering assumptions
- callback-observable mixed state

Important semantic split:

- join:
  - `sender` is the asset source
  - `recipient` is the BPT / LP-benefit receiver

- exit:
  - `sender` is the exiting LP / BPT source
  - `recipient` is the asset receiver

The Vault does not directly validate LP entitlement. The Pool hook owns BPT/share accounting.

---

### 4.2 Batch swap

Relevant file:

- `pkg/vault/contracts/Swaps.sol`

Main risks:

- signed delta confusion
- asset index mismatch
- malformed multihop sentinel
- relayer sender/recipient confusion
- internal balance netting mistakes
- cross-hop rounding leakage

Important behavior:

- `amount == 0` is not a zero-sized swap.
- It is a multihop sentinel.
- The current step's given token must equal the previous step's calculated token.

---

### 4.3 Asset Manager accounting

Relevant files:

- `pkg/vault/contracts/AssetManagers.sol`
- `pkg/vault/contracts/balances/BalanceAllocation.sol`
- `pkg/vault/contracts/balances/TwoTokenPoolsBalance.sol`

Main risks:

- phantom managed balances
- low cash / high managed exit or swap behavior
- `UPDATE` creating false solvency
- managed balances treated as cash
- Asset Manager authorization boundary

Asset Manager operations have different accounting meanings:

- `WITHDRAW`: moves `cash -> managed`, total unchanged
- `DEPOSIT`: moves `managed -> cash`, total unchanged
- `UPDATE`: overwrites managed balance, total may change

`UPDATE` is the profit/loss reporting trust boundary.

---

### 4.4 BPT supply layer

Relevant files:

- `pkg/pool-utils/contracts/BalancerPoolToken.sol`
- `pkg/pool-weighted/contracts/WeightedPool.sol`
- `pkg/pool-weighted/contracts/BaseWeightedPool.sol`
- `pkg/pool-weighted/contracts/WeightedMath.sol`

Main risks:

- mint-before-fund
- burn-after-withdraw
- pending protocol fee BPT not included in effective supply
- BPT valuation using raw `totalSupply()`
- composable stable BPT-in-pool effective supply

BPT is the LP share token for a specific Balancer pool. Each pool has its own independent BPT.

---

### 4.5 Read-only reentrancy

Relevant files:

- `pkg/pool-utils/contracts/lib/VaultReentrancyLib.sol`
- `pkg/pool-weighted/contracts/WeightedPool.sol`

Main risks:

- external integrations reading rate/supply/invariant during Vault context
- derived view consumed as oracle while Vault and Pool states are temporarily inconsistent
- missing `ensureNotInVaultContext` on sensitive paths

Important point:

    view functions can be dangerous if they expose derived financial state during inconsistent execution context.

---

## 5. Tests Written

### 5.1 `BalancerBatchSwapReview.t.sol`

Covers:

- valid `GIVEN_IN` multihop net settlement
- middle asset netting to zero
- user/Vault balance deltas matching returned `assetDeltas`
- malformed multihop sentinel rejection
- added follow-up coverage for multihop/sentinel behavior

Conclusion:

    batchSwap net settlement and amount==0 sentinel behavior are correctly characterized in tested paths.

Security relevance:

- validates signed delta convention
- validates intermediate asset netting
- validates `amount == 0` as multihop sentinel, not zero-sized swap
- checks malformed token continuation is rejected

---

### 5.2 `BalancerAssetManagementReview.t.sol`

Covers:

- `WITHDRAW`: `cash -> managed`, total unchanged
- `DEPOSIT`: `managed -> cash`, total unchanged
- `UPDATE`: managed overwritten, total changes
- non-manager cannot mutate managed balance
- managed balance cannot be spent as Vault cash in tested swap path
- added low-cash/high-managed liquidity boundary coverage

Conclusion:

    cash/managed accounting behaves as an explicit custody-domain split.
    UPDATE is a trusted profit/loss reporting boundary.
    Managed balance is not immediately spendable Vault cash.

Security relevance:

- characterizes the `cash / managed / total` accounting model
- identifies `UPDATE` as the trusted profit/loss reporting boundary
- verifies cash is the immediate settlement liquidity
- verifies managed balance is not directly spendable by swap settlement

---

### 5.3 `BalancerBptReview.t.sol`

Covers:

- fresh pool: `getActualSupply() == totalSupply()`
- proportional join mints BPT and increases Vault balances
- exit burns BPT and reduces Vault balances conservatively
- added BPT share-accounting sanity checks

Conclusion:

    clean no-fee-debt BPT mint/burn paths behave as expected.
    Pending protocol fee BPT remains a future deeper test target.

Security relevance:

- validates clean BPT mint/burn behavior
- distinguishes clean no-fee-debt state from future pending-fee-debt tests
- supports the BPT coherence invariant in basic join/exit paths

---

### 5.4 `BalancerReadOnlySafetyReview.t.sol`

Covers:

- protected view callable outside Vault context
- protected view reverts during join context
- protected view reverts during swap context
- protected view reverts during exit context
- added coverage around active Vault-context protection

Conclusion:

    VaultReentrancyLib correctly protects sensitive views in tested active Vault contexts.

Security relevance:

- validates `VaultReentrancyLib` protection behavior
- models read-only reentrancy protection for sensitive derived views
- supports the invariant that rate/supply/invariant views must not be consumed in mixed Vault state

---

### 5.5 Supporting tests

Supporting files:

- `BalancerPermissionsTemplate.t.sol`
- `BalancerLiquidityTemplate.t.sol`
- `BalancerImportsSmoke.t.sol`
- `BalancerScaffold.t.sol`
- `BalancerScaffold.sol`

These provide baseline coverage for:

- authorization wiring
- pool initialization
- basic LP flows
- imports/scaffold correctness
- permission template behavior
- liquidity template behavior

---

## 6. Issue Candidates

No confirmed exploitable vulnerability was identified.

The review produced issue candidates and follow-up targets rather than validated reportable bugs.

### IC-01: `batchSwap` net settlement and multihop sentinel behavior

Status: characterized

The tested paths show correct net settlement for `GIVEN_IN` multihop swaps and rejection of malformed sentinel routing.

Future work:

- `GIVEN_OUT` multihop coverage
- relayer and internal-balance fuzzing
- multi-pool cyclic route rounding analysis

---

### IC-02: Asset Manager cash/managed accounting

Status: characterized

The tested paths show that:

- `WITHDRAW` and `DEPOSIT` preserve total while moving balances between custody domains
- `UPDATE` acts as the trusted reporting boundary
- managed balance cannot be spent as immediate Vault cash in tested swap path

Future work:

- exit path under high managed / low cash
- external integrator BPT valuation using managed balances
- two-token shared packing tests

---

### IC-03: Read-only reentrancy / derived view safety

Status: characterized

The tested mock pool confirms that protected views revert when called during active Vault join, swap, or exit context.

Future work:

- external oracle-consumer mock
- concrete `getActualSupply()` or `getRate()` misuse scenario
- composable stable effective-supply read during mixed state

---

### IC-04: Actual supply vs raw BPT supply

Status: partially characterized

Clean no-fee-debt paths behave as expected. Pending protocol fee BPT was not fully modeled.

Future work:

- construct `getActualSupply() > totalSupply()` state
- test join/exit before and after protocol fee realization
- test protocol fee single-charge and no double-counting

---

### IC-05: Protocol fee realization timing

Status: open follow-up

The review identified this as a high-value surface but did not fully model protocol fee debt, fee cache update, or recovery-mode reset.

Future work:

- `_beforeJoinExit` and `_afterJoinExit` differential tests
- `_beforeProtocolFeeCacheUpdate` old-fee cut-off tests
- `_onDisableRecoveryMode` fee baseline reset tests

---

### IC-06: Non-standard token behavior

Status: assumption-boundary

Non-standard ERC20 behavior remains an integration/support-boundary issue unless explicitly supported by scope.

Future work:

- fee-on-transfer and rebasing mock tests
- classify results under token support assumptions

---

### IC-07: Managed pool token mutation

Status: open privileged-path review surface

Managed pools can pass through intentionally invalid states during add/remove token flows.

Future work:

- managed pool add/remove invalid-state tests
- token ordering and weight redistribution checks
- trapped-fund or distorted-share state tests

---

## 7. Positive Security Observations

### 7.1 Vault/Pool separation is clear

Balancer V2 strongly separates:

- Vault custody and settlement
- Pool pricing and BPT logic
- Asset Manager external capital management

This makes the system easier to reason about than protocols where settlement, accounting, and risk logic are deeply interwoven.

---

### 7.2 Batch swap netting is explicit

`assetDeltas` provide a clear signed accounting model for final settlement.

The tested multihop path shows that intermediate assets can net to zero while final user and Vault deltas remain consistent.

---

### 7.3 Cash and managed balances are cleanly separated

`BalanceAllocation` makes the distinction between immediate Vault cash and externally managed claims explicit.

The tests confirm that managed balances do not become spendable cash in the reviewed swap path.

---

### 7.4 Read-only safety is explicitly acknowledged

`VaultReentrancyLib` exists specifically to protect sensitive pool-side views from unsafe Vault context.

The tests demonstrate expected guard behavior across join, swap, and exit.

---

## 8. Important Lessons

### 8.1 Balancer is architecturally clean

Balancer V2 is easier to reason about than protocols where collateral, settlement, pricing, and position state are deeply entangled.

The separation is strong:

    Vault = custody and settlement
    Pool = math and BPT logic
    Asset Manager = external capital-management boundary

---

### 8.2 Clean architecture does not mean shallow risk

The hard problems are not messy control flow. The hard problems are accounting boundaries:

- cash vs managed
- totalSupply vs actualSupply
- local swap step vs global batch delta
- pool invariant vs Vault settlement
- view function vs safe oracle value
- external managed claim vs immediate liquidity

---

### 8.3 Read-only reentrancy is a major integration theme

The key lesson:

    view functions are not automatically safe if they derive value from temporarily inconsistent financial state.

This is highly relevant for external protocols using BPT, rate, invariant, or supply values.

---

### 8.4 Asset Managers create a clear trust boundary

`managed` is not cash. It is an external claim.

The protocol can account for it, but immediate settlement must remain constrained by Vault cash.

---

### 8.5 Protocol fee debt complicates BPT valuation

Pending protocol fee BPT means raw ERC20 `totalSupply()` is not always the correct economic supply.

This is a subtle but important BPT valuation issue.

---

## 9. Residual Research Targets

Future deeper tests should focus on:

- constructing `getActualSupply() > totalSupply()` states
- protocol fee single-charge / double-charge tests
- `GIVEN_OUT` multihop batch swaps
- composable stable effective supply
- high managed / low cash exit paths
- managed pool add/remove invalid-state transitions
- external oracle-consumer read-only reentrancy mock
- two-token shared packing fuzz
- recovery exit with stale or reverting rate providers
- fee-on-transfer / non-standard token support-boundary classification

---

## 10. Overall Conclusion

Week 12 Balancer V2 review is complete as a structured learning and public artifact pass.

No confirmed vulnerability was found, but the review produced:

- threat model
- function notes
- invariants
- issue candidates
- final review
- targeted Foundry tests

The most important reviewed themes were:

- Vault settlement conservation
- batchSwap signed-delta netting
- Asset Manager cash/managed accounting
- BPT mint/burn coherence
- actual supply vs raw supply
- read-only reentrancy protection

Balancer V2 is a valuable reference protocol for DeFi accounting-invariant methodology.

It is not the most convoluted protocol, but it is one of the cleanest examples of a shared settlement layer, multi-asset pool accounting, external asset management, and LP-share valuation living in one system.