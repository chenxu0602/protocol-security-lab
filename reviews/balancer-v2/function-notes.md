# Balancer V2 Function Notes

Derived from `threat-model-final.md`. This artifact is organized around exploit paths and accounting boundaries rather than ABI completeness.

Factory paths are included as configuration-risk notes, not as primary Week 12 review scope unless they directly affect pool accounting, fee configuration, rate providers, or BPT self-reference.

## Core Review Invariants

1. Vault custody coverage  
   For each supported token, the Vault’s actual token balance must cover all Vault-custodied liabilities, including pool cash balances and user internal balances, excluding explicitly managed balances and other protocol-defined non-custodied claims.

2. Pool-token accounting  
   For each pool-token, `total = cash + managed`.

3. Settlement conservation  
   For normal swap/join/exit/flash-loan paths, Vault cash deltas must equal user settlement plus protocol-fee settlement. For Asset Manager paths, `cashToManaged` and `managedToCash` must preserve total, while `setManaged` is the only path that may explicitly change total without direct Vault token movement.

4. BPT coherence  
   Pool balances as tracked by the Vault, together with the pool invariant and fee rules, must back BPT supply. Mint and burn quantities must remain coherent with invariant-based pricing after applying protocol fee rules.

5. Batch netting  
   Sum of per-step swap deltas must equal final `assetDeltas` settlement.

6. Read-only safety  
   Derived views such as rate, supply, and invariant must not be treated as safe oracle inputs during inconsistent Vault context.

## 1. Vault Settlement Kernel

### `joinPool` / `exitPool` / `_joinOrExit` / `_callPoolBalanceChange`
Files:
- `pkg/vault/contracts/PoolBalances.sol`

- `joinPool` and `exitPool` funnel into `_joinOrExit`, which validates ordered registered tokens, reads balances, calls the pool hook, processes token movements, then writes final balances.
- The core risk is settlement ordering: pool math is computed from pre-state balances, while actual transfers, fee payment, and final balance writes happen afterward.
- Important semantic split:
  - join: `sender` is the asset source; `recipient` is the BPT / LP-benefit receiver.
  - exit: `sender` is the exiting LP / BPT source; `recipient` is the asset receiver.
  - Vault does not validate LP entitlement directly; the Pool hook owns BPT/share accounting.
- `_callPoolBalanceChange` trusts `onJoinPool` / `onExitPool` to return economically coherent `amountsInOrOut` and `dueProtocolFeeAmounts`. Vault mainly performs structural enforcement around ordering and settlement.
- Review focus:
  - mint/burn vs transfer finalization ordering
  - protocol fee realization timing
  - token ordering / asset ordering assumptions
  - joins/exits where fee amount exceeds nominal token delta
  - whether callback-observable mixed state can leak value

### `swap`
Files:
- `pkg/vault/contracts/Swaps.sol`

- `swap` builds a `SwapRequest`, calls `_swapWithPool`, enforces the user limit, then performs receive/send settlement.
- Swap fee and pricing are pool-side concerns. `Swaps.sol` treats `amountCalculated` as the final post-fee economic result and only enforces user limits and settlement.
- Main review question is whether Vault settlement remains safe if pool-returned amounts are wrong, stale, asymmetrically rounded, or computed from manipulable intermediate state.
- Review focus:
  - exact-in / exact-out rounding symmetry
  - stale balances during pool hook read
  - non-standard token semantics at settlement boundary
  - whether user limit checks fully bound economic loss

### `batchSwap` / `_swapWithPools`
Files:
- `pkg/vault/contracts/Swaps.sol`

- `batchSwap` is one of the highest-value Balancer-native surfaces because it nets signed deltas across indexed assets and settles only the aggregate.
- Sign convention:
  - `assetDeltas[i] > 0`: Vault must receive this asset from `funds.sender`.
  - `assetDeltas[i] < 0`: Vault must send this asset to `funds.recipient`.
  - Each step adds `amountIn` to the input-asset delta and subtracts `amountOut` from the output-asset delta.
- `amount == 0` is a multihop sentinel, not a zero-sized swap. The current step’s given token must equal the previous step’s calculated token.
- Review focus:
  - relayer execution with sender/recipient separation
  - internal-balance debit/credit interaction with net deltas
  - asset index mismatch / sign confusion
  - multihop sentinel correctness
  - compounding rounding leakage across hops

### `managePoolBalance`
Files:
- `pkg/vault/contracts/AssetManagers.sol`

- This is the direct mutation surface for `cash <-> managed` accounting and one of the highest-blast-radius trusted-role paths.
- The key issue is not just authorization, but whether managed balances remain truthful enough for solvency and exit assumptions.
- Review focus:
  - phantom managed balances
  - exits with high managed / low cash
  - whether `UPDATE` can create false solvency
  - whether pool valuation treats managed balances too optimistically

### `flashLoan`
Files:
- `pkg/vault/contracts/FlashLoans.sol`

- Flash loans validate repayment using pre-loan and post-loan `balanceOf` checks, with fee requirements enforced against the post-loan balance.
- This makes token semantics important, but treat non-standard ERC20 behavior as an integration/support-boundary question first; only escalate if the token type is in supported scope and the failure causes value loss under supported assumptions.
- Review focus:
  - token sorting / uniqueness assumptions
  - repayment-before-fee logic
  - whether supported token behaviors can confuse repayment accounting
  - whether flash-loan context can manipulate downstream Balancer reads

## 2. Vault Balance Storage and Registration

### `BalanceAllocation`
Files:
- `pkg/vault/contracts/balances/BalanceAllocation.sol`

- Encodes each pool-token balance as `cash + managed + lastChangeBlock` in one `bytes32`.
- `cash` is the amount actually held by the Vault.
- `managed` is the amount withdrawn by the token’s Asset Manager.
- `total = cash + managed` is the pool’s economic balance for that token.
- `increaseCash` / `decreaseCash` change total and update `lastChangeBlock`.
- `cashToManaged` / `managedToCash` move value between custody domains without changing total.
- `setManaged` changes total and is the profit/loss reporting trust boundary.
- Review focus:
  - cash/managed conservation
  - `setManaged` phantom-profit / hidden-loss reporting
  - two-token shared packing correctness
  - `lastChangeBlock` semantics for oracle-resistant reads

### `registerTokens` / `deregisterTokens`
Files:
- `pkg/vault/contracts/PoolTokens.sol`

- These are privileged registry mutation paths that also wire asset managers.
- `registerTokens` writes `_poolAssetManagers` before specialization-specific registration.
- `deregisterTokens` assumes the deregistration path has already enforced zero total balance before asset-manager cleanup.
- Review focus:
  - temporary inconsistency during registration
  - deregistration safety with managed balances
  - specialization-specific assumptions for two-token / minimal / general pools

### `TwoTokenPoolsBalance` storage mutation helpers
Files:
- `pkg/vault/contracts/balances/TwoTokenPoolsBalance.sol`

Primary helpers:
- `_setTwoTokenPoolCashBalances`
- `_twoTokenPoolCashToManaged`
- `_twoTokenPoolManagedToCash`
- `_registerTwoTokenPoolTokens`
- `_deregisterTwoTokenPoolTokens`

- These helpers are compact but critical because they implement the actual accounting transitions many higher-level paths depend on.
- Review focus:
  - cash/managed conservation
  - packing and ordering correctness
  - token-pair hash / index correctness
  - whether invalid economic states can be represented or masked

## 3. Reentrancy and Supply Layer

### `ensureNotInVaultContext`
Files:
- `pkg/pool-utils/contracts/lib/VaultReentrancyLib.sol`

- This is Balancer’s explicit read-only reentrancy guard for pool-side functions that may otherwise be callable during Vault operations.
- It relies on a `staticcall` into `manageUserBalance` and uses revert behavior as the signal.
- Review focus:
  - whether all sensitive pool-side rate/invariant/supply paths are actually guarded
  - whether unsafe alternative call paths exist
  - whether external integrators can still observe mixed state through unguarded views

### `getActualSupply`
Files:
- `pkg/pool-weighted/contracts/WeightedPool.sol`

- Returns effective BPT supply by adding pending protocol-fee BPT to `totalSupply()`.
- This is a derived view over pool supply, invariant, normalized weights, and pending protocol-fee accounting.
- The function is explicitly unsafe to consume during Vault join/exit context unless the caller first ensures it is not inside the Vault reentrancy context.
- Review focus:
  - `totalSupply()` vs effective supply confusion
  - pending protocol-fee BPT dilution
  - external protocols using actual supply as valuation input
  - whether sensitive rate/supply views are guarded by `VaultReentrancyLib`

### `_mintPoolTokens` / `_burnPoolTokens`
Files:
- `pkg/pool-utils/contracts/BalancerPoolToken.sol`

- These are tiny wrappers, but they sit exactly on the LP-claim boundary.
- Their security depends on when they are invoked relative to Vault accounting, pool math, and protocol fee realization.
- Review focus:
  - mint-before-fund / burn-after-withdraw sequences
  - protocol fee dilution base
  - composable stable effective supply when BPT is also a pool asset

### `transferFrom` / `decreaseAllowance`
Files:
- `pkg/pool-utils/contracts/BalancerPoolToken.sol`

- Secondary integration surface, not a primary Balancer solvency surface.
- Still worth checking because BPT has custom infinite-allowance and self-transfer behavior, and BPT may itself become part of composable pool accounting.
- Review focus:
  - ERC20 expectation mismatches in integrations
  - BPT-in-pool assumptions around transferability
  - allowance edge cases that affect pool-owned BPT handling

## 4. Weighted Pool Math Hooks

### `BaseWeightedPool.onSwap` / `WeightedMath._calcOutGivenIn` / `WeightedMath._calcInGivenOut`
Files:
- `pkg/pool-weighted/contracts/BaseWeightedPool.sol`
- `pkg/pool-weighted/contracts/WeightedMath.sol`

- `onSwap` applies swap-fee logic and delegates weighted-product math to `WeightedMath`.
- For weighted pools, one swap only changes `tokenIn` and `tokenOut`; other invariant terms cancel out of the local price step.
- Review focus:
  - exact-in / exact-out fee direction
  - `amountOut` rounds down and `amountIn` rounds up
  - max in/out ratio bounds
  - token weight lookup and scaling-factor correctness

### `WeightedMath._calcBptOutGivenExactTokensIn` / `WeightedMath._calcBptOutGivenExactTokenIn`
Files:
- `pkg/pool-weighted/contracts/WeightedMath.sol`

- Calculates BPT minted from invariant growth during joins.
- Proportional joins are fee-free; non-proportional joins charge swap fee on the taxable imbalance.
- Review focus:
  - taxable vs non-taxable split
  - single-token shortcut vs full-array equivalent
  - BPT out rounding down
  - existing LP dilution protection

## 5. Factory and Configuration Risk Notes

### Shared note
Files:
- `pkg/pool-utils/contracts/factories/BasePoolFactory.sol`
- `pkg/pool-utils/contracts/factories/FactoryWidePauseWindow.sol`
- `pkg/pool-weighted/contracts/WeightedPoolFactory.sol`
- `pkg/pool-stable/contracts/ComposableStablePoolFactory.sol`
- `pkg/pool-weighted/contracts/managed/ManagedPoolFactory.sol`
- `pkg/pool-weighted/contracts/lbp/LiquidityBootstrappingPoolFactory.sol`

- These are configuration-risk surfaces rather than the main Week 12 solvency path unless they directly affect fee wiring, rate-provider wiring, BPT self-reference, or emergency controls.

### `_create` / `disable`
Files:
- `pkg/pool-utils/contracts/factories/BasePoolFactory.sol`

- `_create` is the shared deployment funnel; any wiring mistake propagates widely.
- `disable` is an operational boundary affecting future deployments and assumptions about safe rollout.
- Review focus:
  - Vault address wiring
  - protocol fee provider wiring
  - disable semantics vs already deployed pools
  - deployment invariants later assumed by pools

### `getPauseConfiguration`
Files:
- `pkg/pool-utils/contracts/factories/FactoryWidePauseWindow.sol`

- Drives pause-window and buffer configuration inherited by deployed pools.
- Review focus:
  - exact time math
  - expired-window behavior
  - whether child pools can inherit malformed emergency configuration

### `WeightedPoolFactory.create`
Files:
- `pkg/pool-weighted/contracts/WeightedPoolFactory.sol`

- Wires weights, rate providers, swap fee, Vault, fee provider, and explicitly uses empty `assetManagers`.
- Review focus:
  - weight bounds and alignment
  - rate-provider cardinality vs token list
  - whether `no asset managers` is relied on elsewhere as a security assumption

### `ComposableStablePoolFactory.create`
Files:
- `pkg/pool-stable/contracts/ComposableStablePoolFactory.sol`

- Out-of-primary-scope but high-value comparative surface because composable stable pools introduce BPT-in-pool and effective-supply mechanics.
- Wires amplification, rate providers, token rate cache durations, yield-fee exemptions, and BPT self-reference assumptions.
- Review focus:
  - effective-supply assumptions at initialization
  - amp bounds
  - token/rate/cache alignment
  - fee/rate configuration that may create stale or circular valuation

### `ManagedPoolFactory.create`
Files:
- `pkg/pool-weighted/contracts/managed/ManagedPoolFactory.sol`

- Important deployment path for pools with large privileged-control surface.
- Review focus:
  - owner/manager power initialization
  - recovery helper / pause wiring
  - token metadata and weight initialization consistency

### `LiquidityBootstrappingPoolFactory.create`
Files:
- `pkg/pool-weighted/contracts/lbp/LiquidityBootstrappingPoolFactory.sol`

- Schedule-sensitive deployment path.
- Review focus:
  - launch-time weight assumptions
  - `swapEnabledOnStart`
  - pause interaction with active schedules

## 6. Managed Pool Mutation

### `addToken`
Files:
- `pkg/pool-weighted/contracts/managed/ManagedPoolAddRemoveTokenLib.sol`

- This path intentionally registers a zero-balance token in the Vault before liquidity is restored, temporarily placing the pool in an invalid state.
- That makes it one of the most audit-worthy privileged transitions in the codebase.
- Review focus:
  - invalid-state assumptions during token introduction
  - weight rescaling and exact-sum repair
  - BPT prohibition via this path
  - requirement that downstream funding restores solvency before normal operation resumes

### `removeToken`
Files:
- `pkg/pool-weighted/contracts/managed/ManagedPoolAddRemoveTokenLib.sol`

- Removal assumes balance has already been withdrawn and the pool is already in an invalid state where normal value-changing operations revert.
- Review focus:
  - zero-balance precondition enforcement by Vault deregistration
  - swap-and-pop token reorder correctness
  - weight redistribution and rounding
  - whether manager can force trapped-fund or distorted-share states around removal

## P0 Test Targets

- `batchSwap` delta-conservation fuzz with relayer and internal-balance toggles.
- Managed balance phantom-liquidity test with low cash / high managed exit.
- Read-only reentrancy test for pool-side rate/invariant functions guarded by `VaultReentrancyLib`.

## P1 Test Targets

- Fee-on-transfer / non-standard token support-boundary test against Vault accounting and post-transfer cash balance.
- Composable Stable effective-supply and `getRate()` tests before and after fee realization.
- Recovery exit test under stale or reverting rate-provider conditions.
