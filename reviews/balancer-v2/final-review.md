# Balancer V2 Review Note

## Executive Summary

This review studied selected Balancer V2 mechanisms from a DeFi financial-security perspective, with emphasis on Vault accounting, batch swap net settlement, BPT share accounting, Asset Manager cash/managed balances, protocol fee realization, and read-only reentrancy boundaries.

No confirmed exploitable vulnerability was identified in this review pass.

The main output is a structured review artifact consisting of:

- threat model
- function notes
- invariants
- issue candidates
- targeted Foundry review tests

The review confirms several important Balancer V2 design properties through characterization and adversarial-style tests:

- `batchSwap` net settlement preserves final signed asset deltas in tested multihop paths.
- malformed `amount == 0` multihop sentinel use is rejected.
- Asset Manager `cash / managed` transitions preserve the intended balance identity.
- unauthorized managed-balance mutation is rejected.
- managed balances cannot be spent as immediate Vault cash in the tested swap path.
- clean BPT join/exit paths mint and burn BPT consistently with Vault balance movement.
- `VaultReentrancyLib` protects sensitive views from being consumed inside active Vault join/swap/exit context in the tested mock paths.

This review should be read as a mechanism-oriented security study, not as a complete audit of the entire Balancer V2 monorepo.

---

## Scope

Primary files and mechanisms reviewed:

- `pkg/vault/contracts/PoolBalances.sol`
- `pkg/vault/contracts/Swaps.sol`
- `pkg/vault/contracts/AssetManagers.sol`
- `pkg/vault/contracts/FlashLoans.sol`
- `pkg/vault/contracts/PoolTokens.sol`
- `pkg/vault/contracts/balances/BalanceAllocation.sol`
- `pkg/vault/contracts/balances/TwoTokenPoolsBalance.sol`
- `pkg/pool-utils/contracts/lib/VaultReentrancyLib.sol`
- `pkg/pool-utils/contracts/BalancerPoolToken.sol`
- `pkg/pool-weighted/contracts/WeightedPool.sol`
- `pkg/pool-weighted/contracts/BaseWeightedPool.sol`
- `pkg/pool-weighted/contracts/WeightedMath.sol`
- selected factory and managed-pool mutation surfaces

Out-of-primary-scope but referenced for comparative risk:

- composable stable effective supply
- rate-provider caching
- recovery mode under stale or reverting rate providers
- managed pool token add/remove transitions

---

## Methodology

The review was organized around accounting and settlement boundaries rather than ABI completeness.

Primary review questions:

1. Does the Vault's token accounting match actual token custody?
2. Do pool-token balances preserve `cash + managed = total`?
3. Does `batchSwap` correctly net multi-step signed deltas?
4. Are BPT mint/burn operations coherent with invariant growth/shrink?
5. Are pending protocol fee claims reflected in effective BPT supply?
6. Can sensitive rate/supply/invariant views be consumed during inconsistent Vault context?
7. Can Asset Managers create unsafe cash/managed divergence?
8. Do user limits and settlement endpoints protect the correct economic party?
9. Are privileged configuration and mutation paths bounded by clear assumptions?

The review used:

- manual code reading
- threat-model construction
- invariant design
- targeted Foundry tests
- characterization of intended accounting behavior
- candidate issue triage

---

## Mental Model

Balancer V2 separates custody, math, and LP claims:

- Vault holds and settles assets.
- Pool computes swap/join/exit math.
- Pool owns BPT mint/burn logic.
- `BalanceAllocation` defines per-pool-token accounting.
- Asset Manager moves value between Vault cash and external managed claims.
- Protocol fee debt can exist as unminted BPT.
- Derived views may be unsafe during inconsistent Vault context.

The key architectural sentence is:

> Pool calculates. Vault settles. Vault records.

---

## Core Invariants

### Vault custody

For each supported token, the Vault's actual token balance should cover Vault-custodied liabilities, including pool cash balances and user internal balances, excluding explicitly managed balances and other protocol-defined non-custodied claims.

### Pool-token accounting

For each pool-token:

- `total = cash + managed`
- `cash` is immediately available Vault liquidity.
- `managed` is an external claim controlled by the registered Asset Manager.
- `setManaged` is the profit/loss reporting trust boundary.

### Settlement conservation

For swaps, joins, exits, and flash loans, Vault balance deltas should match user settlement plus protocol fee settlement.

For exits:

- pool cash decreases by `amountOut + protocolFeeAmount`

For joins:

- pool cash changes by `amountIn - protocolFeeAmount`

### Batch netting

For `batchSwap`:

- `assetDeltas[i] > 0`: Vault receives asset `i`
- `assetDeltas[i] < 0`: Vault sends asset `i`
- intermediate assets may net to zero

### BPT coherence

BPT mint/burn must reflect invariant growth/shrink after applying fee rules and protocol fee realization.

Important distinction:

- `totalSupply()` is raw minted BPT supply.
- effective supply may include pending protocol fee BPT.

### Read-only safety

Derived views such as rate, supply, invariant, or BPT valuation must not be treated as safe oracle inputs during inconsistent Vault context.

---

## Test Coverage

### `BalancerBatchSwapReview.t.sol`

Reviewed properties:

- valid `GIVEN_IN` multihop batch swap conserves final net asset deltas
- middle asset nets to zero
- user balance deltas match returned `assetDeltas`
- Vault balance deltas match returned `assetDeltas`
- malformed multihop sentinel use reverts

Security relevance:

- validates signed delta convention
- validates intermediate asset netting
- validates `amount == 0` as multihop sentinel, not zero-sized swap
- checks malformed token continuation is rejected

### `BalancerAssetManagementReview.t.sol`

Reviewed properties:

- Asset Manager `WITHDRAW` moves `cash -> managed` and preserves total
- Asset Manager `DEPOSIT` moves `managed -> cash` and preserves total
- Asset Manager `UPDATE` overwrites managed balance and changes total
- non-manager cannot mutate managed balance
- swap cannot spend managed balance as if it were Vault cash

Security relevance:

- characterizes the `cash / managed / total` accounting model
- identifies `UPDATE` as the trusted profit/loss reporting boundary
- verifies cash is the immediate settlement liquidity
- verifies managed balance is not directly spendable by swap settlement

### `BalancerBptReview.t.sol`

Reviewed properties:

- fresh weighted pool has no pending protocol fee supply
- proportional join keeps actual supply aligned with raw supply in a clean state
- exit burns BPT and reduces Vault balances conservatively

Security relevance:

- validates clean BPT mint/burn behavior
- distinguishes clean no-fee-debt state from future pending-fee-debt tests
- supports the BPT coherence invariant in basic join/exit paths

### `BalancerReadOnlySafetyReview.t.sol`

Reviewed properties:

- protected view is callable outside Vault context
- protected view reverts during join context
- protected view reverts during swap context
- protected view reverts during exit context

Security relevance:

- validates `VaultReentrancyLib` protection behavior
- models read-only reentrancy protection for sensitive derived views
- supports the invariant that rate/supply/invariant views must not be consumed in mixed Vault state

### `BalancerPermissionsTemplate.t.sol`

Reviewed properties:

- pool uses the Vault authorizer
- action IDs are stable across pools from the same creator
- unauthorized swap fee update reverts
- authorized swap fee update succeeds

Security relevance:

- confirms expected permission wiring for controlled pool actions
- acts as a baseline template for authorization-boundary tests

### `BalancerLiquidityTemplate.t.sol`

Reviewed properties:

- initialization join seeds Vault balances and mints BPT
- exact BPT exit returns underlying tokens
- second LP can join with exact tokens in

Security relevance:

- baseline liquidity behavior
- sanity check for scaffolded pool initialization and basic LP flows

---

## Findings

No confirmed exploitable vulnerability was identified.

The review produced issue candidates and follow-up targets rather than validated reportable bugs.

---

## Key Review Candidates

### 1. `batchSwap` net settlement and multihop sentinel behavior

Status: characterized

The tested paths show correct net settlement for `GIVEN_IN` multihop swaps and rejection of malformed sentinel routing.

Future work:

- `GIVEN_OUT` multihop coverage
- relayer and internal-balance fuzzing
- multi-pool cyclic route rounding analysis

### 2. Asset Manager cash/managed accounting

Status: characterized

The tested paths show that `WITHDRAW` and `DEPOSIT` preserve total while moving balances between custody domains, and `UPDATE` acts as the trusted reporting boundary.

The added low-cash/high-managed test confirms that managed balance cannot be spent as immediate Vault cash through the tested swap path.

Future work:

- exit path under high managed / low cash
- external integrator BPT valuation using managed balances
- two-token shared packing tests

### 3. Read-only reentrancy / derived view safety

Status: characterized

The tested mock pool confirms that protected views revert when called during active Vault join, swap, or exit context.

Future work:

- external oracle-consumer mock
- concrete `getActualSupply()` or `getRate()` misuse scenario
- composable stable effective-supply read during mixed state

### 4. Actual supply vs raw BPT supply

Status: partially characterized

Clean no-fee-debt paths behave as expected. Pending protocol fee BPT was not fully modeled.

Future work:

- construct `getActualSupply() > totalSupply()` state
- test join/exit before and after protocol fee realization
- test protocol fee single-charge and no double-counting

### 5. Protocol fee realization timing

Status: open follow-up

The review identified this as a high-value surface but did not fully model protocol fee debt, fee cache update, or recovery-mode reset.

Future work:

- `_beforeJoinExit` and `_afterJoinExit` differential tests
- `_beforeProtocolFeeCacheUpdate` old-fee cut-off tests
- `_onDisableRecoveryMode` fee baseline reset tests

### 6. Non-standard token behavior

Status: assumption-boundary

Non-standard ERC20 behavior remains an integration/support-boundary issue unless explicitly supported by scope.

Future work:

- fee-on-transfer and rebasing mock tests
- classify results under token support assumptions

---

## Positive Security Observations

### Vault/Pool separation is clear

The architecture strongly separates:

- Vault custody and settlement
- Pool pricing and BPT logic
- Asset Manager external capital management

This makes the system easier to reason about than protocols where settlement, accounting, and risk logic are deeply interwoven.

### Batch swap netting is explicit

`assetDeltas` provide a clear signed accounting model for final settlement.

The tested multihop path shows that intermediate assets can net to zero while final user and Vault deltas remain consistent.

### Cash and managed balances are cleanly separated

`BalanceAllocation` makes the distinction between immediate Vault cash and externally managed claims explicit.

The tests confirm that managed balances do not become spendable cash in the reviewed swap path.

### Read-only safety is explicitly acknowledged

`VaultReentrancyLib` exists specifically to protect sensitive pool-side views from unsafe Vault context.

The tests demonstrate the expected guard behavior across join, swap, and exit.

---

## Residual Risks and Limitations

This review did not attempt to prove full Balancer V2 safety.

Important residual surfaces:

- pending protocol fee BPT and actual supply divergence
- composable stable BPT-in-pool effective supply
- rate-provider stale or reverting behavior
- recovery mode under broken external dependencies
- managed pool token add/remove invalid-state transitions
- two-token shared packing under fuzzed token order and manager operations
- `GIVEN_OUT` batch swap multihop behavior
- non-standard token support assumptions
- external integrations misusing Balancer derived views

Some risks depend on trust assumptions:

- Asset Managers are trusted for truthful reporting of externally managed balances.
- Pool owners/managers may be privileged depending on pool family.
- Unsupported token behavior should not automatically be treated as a protocol vulnerability.
- External protocols are responsible for safe consumption of Balancer views unless Balancer explicitly guarantees oracle-safe behavior.

---

## Recommendations

### For reviewers

Prioritize future tests around:

1. pending protocol fee BPT
2. `getActualSupply() > totalSupply()`
3. `GIVEN_OUT` batch swap routes
4. high managed / low cash exits
5. composable stable effective supply
6. external oracle-consumer read-only reentrancy mocks

### For integrators

Do not consume Balancer derived views such as rate, invariant, or effective supply during active Vault context.

Where applicable, use Balancer-provided reentrancy guard helpers or ensure the call is not occurring inside a Vault operation.

Distinguish:

- Vault cash liquidity
- externally managed pool claims
- raw BPT total supply
- actual/effective BPT supply

### For protocol designers

Avoid assuming that a pool's economic total balance is identical to immediately available Vault liquidity.

When integrating BPT as collateral or pricing input, account for:

- pending protocol fee BPT
- managed balances
- composable/self-referential BPT supply
- rate-provider behavior
- read-only reentrancy protection

---

## Conclusion

This review did not identify a confirmed Balancer V2 vulnerability.

However, the review produced a structured security map and passing test suite around several of Balancer V2's most important financial-security boundaries:

- Vault settlement conservation
- batch swap signed-delta netting
- Asset Manager cash/managed accounting
- BPT mint/burn coherence
- actual supply vs raw supply awareness
- read-only reentrancy protection

The strongest conclusion is that Balancer V2's core architecture is unusually clean for a complex DeFi protocol:

- Vault settles assets.
- Pool computes math.
- BPT represents pool share claims.
- Asset Managers define an explicit external capital-management boundary.
- Protocol fee debt is treated as an accounting liability that can affect effective supply.
- Derived views require careful context safety.

The remaining high-value research targets are not simple Solidity bugs, but financial-accounting and integration-boundary questions around protocol fee debt, effective supply, managed balances, and read-only state safety.

This makes Balancer V2 a useful reference protocol for DeFi accounting-invariant methodology.