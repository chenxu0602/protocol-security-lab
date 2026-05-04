# Invariants

## Core Accounting Invariants

### 1. Timelock-only execution (no side doors)
- Type: invariant
- Priority: critical
#### Statement
- Any state-changing privileged action must be reachable only through a timelock execute path (or explicitly documented emergency guardian path), never directly via governor/vault externals
#### Why It Matters
- A single overlooked callable function (setParam, sweep, upgrade) can bypass delays/challenges and allow instant takeover/drain.
#### Relevant Mechanisms
- `contracts/governance/ReserveOptimisticGovernor.sol`
- `contracts/staking/StakingVault.sol`
- `contracts/staking/RewardTokenRegistry.sol`
#### What Could Break It
- Honest challenger acts but proposal executes anyway; optimistic governance safety collapses.
- Instant arbitrary execution; upgrade/drain/role takeover.
- Economic invariants can break while executing supply.
- Economic invariants can break while executing borrow and repay.
#### Review Intent
- Catch violations of the intended accounting relationship.
- Turn the protocol’s core safety assumption into a testable review anchor.

### 2. Optimistic state machine soundness
- Type: invariant
- Priority: critical
#### Statement
- For fast proposals: (created) -> (challenge window) -> (queueable) -> (queued) -> (executable). If challenged/canceled at any point, it must never become executable, and state must not be replayable
#### Why It Matters
- Race conditions or missing latching allow challenged proposals to execute, or allow re-queue/re-execute of canceled operations.
#### Relevant Mechanisms
- `contracts/governance/ReserveOptimisticGovernor.sol`
- `test/ReserveOptimisticGovernor.t.sol`
#### What Could Break It
- Honest challenger acts but proposal executes anyway; optimistic governance safety collapses.
- Economic invariants can break while executing supply.
- User balances, reserve balances, or treasury accrual diverge economically.
#### Review Intent
- Catch violations of the intended accounting relationship.
- Turn the protocol’s core safety assumption into a testable review anchor.

### 3. Reward token registry consistency
- Type: invariant
- Priority: medium
#### Statement
- RewardTokenRegistry’s set of reward tokens must contain no duplicates, no removed-but-still-accruing tokens, and vault must not iterate over unbounded lists in a way that can be griefed
#### Why It Matters
- Registry inconsistency causes accounting errors or makes claim/withdraw uncallable due to gas exhaustion.
#### Relevant Mechanisms
- `contracts/staking/RewardTokenRegistry.sol`
- `contracts/staking/StakingVault.sol`
#### What Could Break It
- Unbacked governance power and/or ability to withdraw more than fair share; reward siphoning.
- Asset loss, incorrect share issuance, double-claim, or blocked withdrawals.
- Reward pool drained or unfair distribution; can also DOS due to underflow/overflow in per-user accounting.
- Funds stuck (withdraw requires reward updates); governance weight trapped.
#### Review Intent
- Ensure claim-side accounting remains coherent with reserve-side or pool-side accounting.
- Catch stale-index, scaled-balance, or lazy-settlement mistakes.

## Solvency / Liquidation Invariants

### 4. Reserve-to-claim reconciliation
- Type: invariant
- Priority: high
#### Statement
- Reserve-side liquidity and index state must reconcile with supplier claims and borrower debt after every state transition
#### Why It Matters
- If reserve accounting drifts from user-facing claims, the protocol can silently create or destroy value.
#### Relevant Mechanisms
- `ReserveOptimisticGovernor: optimistic proposal lifecycle (create/challenge/queue/execute/cancel)`
- `ReserveOptimisticGovernor: proposer throttle library integration and time-bucket accounting`
- `ReserveOptimisticGovernor <-> Timelock: operation hash computation, scheduling, replay protection, and role configuration`
#### What Could Break It
- Economic invariants can break while executing borrow and repay.
- Economic invariants can break while executing flash liquidity.
#### Review Intent
- Ensure claim-side accounting remains coherent with reserve-side or pool-side accounting.
- Catch stale-index, scaled-balance, or lazy-settlement mistakes.

### 5. Valuation-to-liquidation coherence
- Type: invariant
- Priority: critical
#### Statement
- Collateral valuation, debt valuation, and liquidation eligibility must be derived from mutually coherent risk inputs
#### Why It Matters
- If solvency inputs diverge, borrowers can be liquidated incorrectly or remain unliquidated while insolvent.
#### Relevant Mechanisms
- `ReserveOptimisticGovernor: optimistic proposal lifecycle (create/challenge/queue/execute/cancel)`
- `ReserveOptimisticGovernor: proposer throttle library integration and time-bucket accounting`
- `ReserveOptimisticGovernor <-> Timelock: operation hash computation, scheduling, replay protection, and role configuration`
#### What Could Break It
- Economic invariants can break while executing withdraw.
- Economic invariants can break while executing liquidation.
- Healthy positions become liquidatable too early, or unhealthy positions remain under-liquidated.
- Oracle or valuation drift causes a liquidation boundary to be crossed incorrectly.
#### Review Intent
- Prevent wrongful liquidation of solvent users or healthy positions.
- Catch valuation drift, close-factor mistakes, or collateral/debt desynchronization.

## Fee / Treasury Invariants

### 6. Shares↔assets coherence (staking vault)
- Type: invariant
- Priority: critical
#### Statement
- At all times: totalAssets() must be consistent with underlying.balanceOf(vault) (modulo explicitly tracked pending rewards/fees), and totalShares must map to pro-rata claims without allowing share inflation via rounding/donation
#### Why It Matters
- Any mismatch can mint unbacked voting power or allow withdrawals of more underlying than deposited.
#### Relevant Mechanisms
- `contracts/staking/StakingVault.sol`
- `test/StakingVault.t.sol`
#### What Could Break It
- Fee split or treasury accrual is applied on the wrong basis or in the wrong order.
#### Review Intent
- Ensure claim-side accounting remains coherent with reserve-side or pool-side accounting.
- Catch stale-index, scaled-balance, or lazy-settlement mistakes.
- Catch negative drift or double counting in fee and treasury paths.

### 7. Deposit/withdraw reward checkpoint correctness
- Type: invariant
- Priority: high
#### Statement
- On deposit/withdraw/transfer (if supported), user reward checkpoints must update such that users neither lose earned rewards nor can double-claim via checkpoint manipulation
#### Why It Matters
- Incorrect checkpointing leaks rewards or enables free-riding (deposit after accrual then claim).
#### Relevant Mechanisms
- `contracts/staking/StakingVault.sol`
#### What Could Break It
- Unbacked governance power and/or ability to withdraw more than fair share; reward siphoning.
- Asset loss, incorrect share issuance, double-claim, or blocked withdrawals.
- Reward pool drained or unfair distribution; can also DOS due to underflow/overflow in per-user accounting.
- Funds stuck (withdraw requires reward updates); governance weight trapped.
#### Review Intent
- Ensure claim-side accounting remains coherent with reserve-side or pool-side accounting.
- Catch stale-index, scaled-balance, or lazy-settlement mistakes.
- Catch negative drift or double counting in fee and treasury paths.

### 8. Reward index monotonicity & per-token isolation
- Type: operational_property
- Priority: high
#### Statement
- For each reward token i, rewardPerShare_i is monotonic non-decreasing and claimable_i depends only on i’s index and user checkpoint for i (no cross-token state bleed)
#### Why It Matters
- Cross-token mixing or non-monotonic indices enable draining one token via operations on another or negative accrual underflows.
#### Relevant Mechanisms
- `contracts/staking/StakingVault.sol`
- `contracts/staking/RewardTokenRegistry.sol`
#### What Could Break It
- Unbacked governance power and/or ability to withdraw more than fair share; reward siphoning.
- Reward pool drained or unfair distribution; can also DOS due to underflow/overflow in per-user accounting.
- Funds stuck (withdraw requires reward updates); governance weight trapped.
- Economic invariants can break while executing supply.
#### Review Intent
- Ensure claim-side accounting remains coherent with reserve-side or pool-side accounting.
- Catch stale-index, scaled-balance, or lazy-settlement mistakes.
- Catch negative drift or double counting in fee and treasury paths.

## Governance / Configuration Invariants

### 9. Action hash integrity (proposal payload immutability)
- Type: operational_property
- Priority: critical
#### Statement
- The (targets, values, calldatas) approved at propose-time must be exactly those queued/executed; operationId/hash computation must be consistent across propose/queue/execute
#### Why It Matters
- If an attacker can cause a different payload to execute than what was challengeable/voted, governance becomes a payload-substitution attack surface.
#### Relevant Mechanisms
- `contracts/governance/ReserveOptimisticGovernor.sol`
#### What Could Break It
- Attacker gets harmless proposal approved/challenge window passes, but executes malicious calldata/target/value via mismatched operation id or mutated arrays.
- Malicious proposer floods proposals/queues, preventing legitimate governance actions or overwhelming challengers.
- New governor/vault instances backdoored; governance upgrade path compromised.
#### Review Intent
- Catch violations of the intended accounting relationship.
- Turn the protocol’s core safety assumption into a testable review anchor.

### 10. Throttle conservation & anti-spam
- Type: operational_property
- Priority: high
#### Statement
- Within each 12-hour window, each proposer’s consumed throttle quota must equal the number of optimistic proposals created (net of allowed cancellations if intended), with no bypass via reentrancy or timestamp edge cases
#### Why It Matters
- Throttle failure leads to governance DOS (queue flooding) or stealthy rapid-fire malicious proposals that outpace monitoring/challenge.
#### Relevant Mechanisms
- `contracts/governance/ReserveOptimisticGovernor.sol`
#### What Could Break It
- Malicious proposer floods proposals/queues, preventing legitimate governance actions or overwhelming challengers.
- New governor/vault instances backdoored; governance upgrade path compromised.
#### Review Intent
- Catch violations of the intended accounting relationship.
- Turn the protocol’s core safety assumption into a testable review anchor.

### 11. Version monotonicity & pinning
- Type: operational_property
- Priority: critical
#### Statement
- If versions are intended to be append-only, the registry must prevent overwriting existing version->implementation bindings; if overwrite is allowed, it must only occur through timelocked governance with explicit eventing and/or delay
#### Why It Matters
- Silent replacement/downgrade to malicious logic is equivalent to an upgrade attack.
#### Relevant Mechanisms
- `contracts/artifacts/ReserveOptimisticGovernanceVersionRegistryDeployer.sol`
- `contracts/artifacts/ReserveOptimisticGovernorDeployerDeployer.sol`
#### What Could Break It
- New governor/vault instances backdoored; governance upgrade path compromised.
#### Review Intent
- Catch violations of the intended accounting relationship.
- Turn the protocol’s core safety assumption into a testable review anchor.

### 12. Initializer/constructor parameter correctness (deployer determinism)
- Type: operational_property
- Priority: critical
#### Statement
- Deployed governor/vault/registry instances must be initialized with the intended roleRegistry/timelock/guardian/token addresses; deployers must not allow attacker-controlled args or initcode substitution
#### Why It Matters
- Mis-initialization yields permanent loss of control or instant attacker admin rights even if on-chain governance is correct.
#### Relevant Mechanisms
- `contracts/artifacts/ReserveOptimisticGovernorDeployer.sol`
- `contracts/artifacts/StakingVaultDeployer.sol`
- `contracts/artifacts/RewardTokenRegistryDeployer.sol`
#### What Could Break It
- Economic invariants can break while executing parameter updates.
#### Review Intent
- Catch violations of the intended accounting relationship.
- Turn the protocol’s core safety assumption into a testable review anchor.
