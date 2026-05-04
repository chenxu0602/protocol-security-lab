# Function Notes

## Governance Core: initialization, timelock binding, and upgrade authority (A1/A2/A8)

### `ReserveOptimisticGovernor.initialize(OptimisticGovernanceParams optimisticGovParams, StandardGovernanceParams standardGovParams, uint256 _proposalThrottleCapacity, address _token, address _timelockController, address _selectorRegistry)`
- Priority: critical
- Support tier: secondary_support
- Sets the governor’s *trust roots*: voting token, TimelockController executor, and selector registry used to constrain/route optimistic calls.
- If mis-initialized or re-initializable, attacker can reroute execution authority or disable governance safety checks (A8), effectively bypassing timelock (A1).
- Observed from code:
  - Function is `public initializer` in `contracts/governance/ReserveOptimisticGovernor.sol` (around line 91).
  - Excerpt shows `__Governor_init("Reserve Optimistic Governor")` is called.
  - Excerpt shows `_setProposalThrottle(_proposalThrottleCapacity)`, `_setOptimisticParams(optimisticGovParams)`, and assignment of `selectorRegistry`.
- Flow:
  - External caller invokes `initialize(...)` (UUPS initializer).
  - Calls OpenZeppelin `__Governor_init("Reserve Optimistic Governor")` (sets name, Governor base init).
  - (From excerpt) initializes UUPS via `__UUPSUpgradeable_init()` and sets throttle and optimistic params via internal setters.
  - Sets `selectorRegistry = OptimisticSelectorRegistry(payable(_selectorRegistry))`.
  - (Not shown in excerpt) expected: wires GovernorTimelockControl + voting token + standard params; ensure no later mutable linkage.
- Inferred risks:
  - UUPS + timelock-governed upgrade: if `onlyGovernance` is miswired or executor miscomputed, upgrades can be triggered by non-timelock entity (A1/A8).
  - Selector registry is a policy oracle: if it can be swapped or misconfigured, optimistic proposals may execute selectors that should require standard governance.
  - If `_token` is incorrect or has nonstandard `getPastVotes` semantics, standard governance quorum/threshold checks can be bypassed (governance capture).
- Review hypotheses:
  - GovernorTimelockControl initialization (`__GovernorTimelockControl_init`) and token init (`__GovernorVotes_init`) occur in `initialize` (not visible in excerpt); confirm ordering and correctness.
  - `selectorRegistry` may be upgradeable itself; ensure governor trusts *address* not returned data that could change semantics over time.
- Review focus:
  - A8: Are `_token`, `_timelockController`, `_selectorRegistry` validated as nonzero and correct contract types (code-size), and are they immutable after init (no setter exists)?
  - A1: Does any function allow execution of arbitrary calls *without* going through TimelockController once initialized (including UUPS upgrade path, emergency paths, optimistic fast path)?
  - A2: Is proposal ID / timelock operation ID derived from payload in a collision-resistant way, and does `initialize` configure salt/predecessor semantics consistently for both optimistic and standard proposals?
  - Can `initialize` be front-run on a proxy deployment (uninitialized proxy) to seize ownership/roles? Verify deployer flow initializes atomically.

### `ReserveOptimisticGovernor._authorizeUpgrade(address newImplementation)`
- Priority: critical
- Support tier: primary
- Defines who can upgrade the governor implementation (directly controls all future governance semantics).
- Must be strictly timelock-only; any alternative admin/owner path is an instant governance takeover (A1/A8).
- Observed from code:
  - `_authorizeUpgrade(address)` is `internal override onlyGovernance { }` in `ReserveOptimisticGovernor.sol` (~line 456).
  - `_executor()` is overridden to return `super._executor()` from `GovernorUpgradeable`/`GovernorTimelockControlUpgradeable` diamond.
- Flow:
  - Proxy upgrade call hits UUPS `upgradeTo/upgradeToAndCall`.
  - UUPS calls `_authorizeUpgrade(newImplementation)` before changing implementation.
  - This override enforces `onlyGovernance` (OZ Governor modifier) → expected to require timelock execution context.
- Inferred risks:
  - If timelock is misconfigured (proposer/executor roles), attacker can get execution privileges and thus upgrade governor to a malicious implementation.
  - If proposal execution path can be bypassed (e.g., optimistic execution not routed through timelock), upgrade gate may be bypassed too.
- Review hypotheses:
  - Confirm that `onlyGovernance` cannot be satisfied by direct calls from the governor itself (edge case when `_executor()` returns address(this)).
  - Confirm there is no `upgradeTo` exposure in implementation due to missing UUPS proxiableUUID checks in deployment context.
- Review focus:
  - A1: Does `onlyGovernance` in this contract *actually* mean “called by timelock executor” (check `_executor()` override and GovernorTimelockControl wiring)?
  - A8: Can `_executor()` be changed (e.g., timelock address mutation) after init? If so, upgrade authority can be rerouted.
  - Is there any other upgrade surface (beacon/proxy admin, EIP-1967 admin slot) besides UUPS that could be used?
  - Test: attempt direct upgrade call from EOAs, from guardian, from deployer; ensure revert in all cases.

### `ReserveOptimisticGovernor.setProposalThrottle(uint256 newProposalThrottleCapacity)` / `_setProposalThrottle(uint256)`
- Priority: high
- Support tier: primary
- Governance-controlled tuning of optimistic proposal rate limiting; directly affects DoS resistance and challenger workload (A4).
- A mis-set throttle (0, too high, overflow) can either freeze liveness or remove spam protection.
- Observed from code:
  - `setProposalThrottle(uint256)` is `external onlyGovernance` in `ReserveOptimisticGovernor.sol` (~line 116).
  - There are view helpers `proposalThrottleCapacity()` and `proposalThrottleCharges(address)` indicating storage of `capacity` and per-account charges.
- Flow:
  - `setProposalThrottle(...)` callable only via `onlyGovernance` (timelock).
  - Internal `_setProposalThrottle` applies validation and writes `proposalThrottle.capacity` (implementation detail inferred from getter usage).
  - Throttle values used later during optimistic propose path to charge proposer budget (not in excerpt).
- Inferred risks:
  - Throttle logic often fails on boundary conditions: window rollover, cancellation refund semantics, and reentrancy during propose (A4).
  - If throttle library is deployed separately (see deployer), linking mistakes could cause different throttle semantics than audited source.
- Review hypotheses:
  - The actual throttling charge occurs in the optimistic propose function (not in candidate list); verify the propose function increments charges *before* any external calls/events that could reenter and propose again.
  - If cancellations exist, confirm they do not refund charges in a way that enables “propose-cancel-propose” bursts within the same window.
- Review focus:
  - A4: What are the allowed bounds for `newProposalThrottleCapacity`? Can governance set it to 0 or extremely high and break assumptions in proposer-charging logic?
  - Does changing capacity retroactively affect accounts’ outstanding charges (e.g., underflow/overcredit) or only future charging?
  - Is the throttle identity key `msg.sender` vs EIP-712 signer vs proposal “proposer” field? Can attackers bypass by using many contracts (sybil) or delegatecalls?
  - Test: change throttle mid-window and verify charge computation doesn’t allow immediate burst beyond intended cap.

### `ReserveOptimisticGovernor.setOptimisticParams(OptimisticGovernanceParams params)` / `_setOptimisticParams(...)`
- Priority: high
- Support tier: secondary_support
- Governance-controlled tuning of the optimistic safety envelope (veto period, veto threshold, etc.).
- Misconfiguration can silently collapse the challenge window or make veto impossible (A3).
- Observed from code:
  - `setOptimisticParams(...)` is `external onlyGovernance` in `ReserveOptimisticGovernor.sol` (~line 120).
- Flow:
  - Call via timelock (`onlyGovernance`).
  - Internal `_setOptimisticParams` validates and writes optimistic governance parameters used by optimistic proposal path and/or state evaluation.
- Inferred risks:
  - Parameter drift risk: applying *live* params to existing proposals is a common governance footgun (can be exploited by scheduling param change + malicious fast proposal).
- Review hypotheses:
  - Confirm whether optimistic proposals store `vetoEnd`/`vetoPeriod` at creation; add tests for param changes mid-lifecycle.
- Review focus:
  - A3: Can governance set `vetoPeriod=0` (instant execution) or `vetoThreshold=0` (anyone can veto/start confirmation?) or `>1e18` (unreachable)? What bounds exist?
  - If params change while optimistic proposals are in-flight, which params apply: snapshot-at-create or live-at-execution? Ensure no retroactive weakening of safety guarantees.
  - Does `vetoThreshold` rely on total supply at snapshot vs current supply? Check manipulation via mint/burn of governance token.

## StakingVault: share accounting, withdrawals, and unstaking delay (A5/A8)

### `StakingVault.initialize(string _name, string _symbol, IERC20 _underlying, address _initialAdmin, uint256 _rewardPeriod, uint256 _unstakingDelay)`
- Priority: critical
- Support tier: secondary_support
- Establishes the vault’s accounting domain: underlying asset, reward schedule parameters, and admin role for future configuration.
- Also deploys/links an `UnstakingManager`, creating an external-value boundary for withdrawals (delay escrow).
- Observed from code:
  - `initialize(...)` is `external initializer` in `contracts/staking/StakingVault.sol` (~line 144).
  - Requires `_initialAdmin != address(0)` with `Vault__InvalidAdmin` error.
  - Creates `unstakingManager = new UnstakingManager(_underlying)` and sets `nativeRewardsLastPaid = block.timestamp` (visible in excerpt).
- Flow:
  - External caller invokes `initialize(...)` (initializer).
  - Requires `_initialAdmin != address(0)`.
  - (From excerpt) constructs `unstakingManager = new UnstakingManager(_underlying)` (external contract creation).
  - Sets `nativeRewardsLastPaid = block.timestamp` (reward time anchor).
  - (Not shown) expected: initialize ERC20 name/symbol, set admin/roles, set rewardPeriod and unstakingDelay.
- Inferred risks:
  - If `unstakingManager` holds escrowed assets, bugs there are equivalent to vault loss; creation inside init means a deterministic address but also an extra contract to audit.
  - If underlying is ERC777 or has callbacks, initialization and later deposits/withdrawals may be reentrancy-sensitive.
- Review hypotheses:
  - Confirm whether `UnstakingManager` can be replaced later; if yes, treat as privileged drain vector.
  - Verify ERC4626 invariants hold from the first deposit (avoid classic first-depositor share price manipulation if any virtual shares/seed is absent).
- Review focus:
  - A8: Is `initialize` callable only once and is it called atomically by the deployer? Uninitialized implementation/proxy takeover risk.
  - A5: Does the vault restrict `_underlying` to non-rebasing/non-fee-on-transfer, or does it correctly account for balance changes independent of transfers?
  - UnstakingManager trust boundary: who controls it, can it be upgraded, and can it pull underlying out of the vault unexpectedly?
  - Are `_rewardPeriod` and `_unstakingDelay` bounded to prevent overflows/div-by-zero or griefing (e.g., rewardPeriod=0)?

### `StakingVault._withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)` (override)
- Priority: critical
- Support tier: secondary_support
- Primary value-out path: burns shares and reduces internal asset accounting; also accrues/settles rewards as part of withdrawal sequencing.
- Because it overrides ERC4626 `_withdraw`, ordering mistakes can create share/asset drift (A5) or reward overclaim via reentrancy (A6).
- Observed from code:
  - Function is `internal override` and has `accrueRewards(_owner, _receiver)` modifier in `StakingVault.sol` (~line 266).
  - Updates `totalDeposited` and `nativeBalanceLastKnown` by subtracting `_assets` before calling super.
  - Comment indicates `nativeBalanceLastKnown` is set again at bottom of function (not shown).
- Flow:
  - Entry via ERC4626 `withdraw`/`redeem` → calls overridden `_withdraw`.
  - Modifier `accrueRewards(owner, receiver)` runs first (updates global/user indices before balance changes; exact internals not shown).
  - Mutates vault accounting: `totalDeposited -= assets; nativeBalanceLastKnown -= assets;` (excerpt).
  - Calls `super._withdraw(...)` (ERC4626) which typically: spend allowance if caller != owner → burn shares → transfer assets to receiver (external call to underlying).
  - (Excerpt notes) `nativeBalanceLastKnown update is redundant, final value set at bottom of function` indicating additional reconciliation step later.
- Inferred risks:
  - Double-entry internal accounting (`totalDeposited`, `nativeBalanceLastKnown`, ERC4626 totalAssets) is a frequent source of invariant breaks under nonstandard ERC20 behavior.
  - Reward accrual in modifiers + external transfers is a classic reentrancy/external-call ordering hazard.
- Review hypotheses:
  - Confirm whether `super._withdraw` is called before or after any interaction with `UnstakingManager`; write tests for withdraw-to-contract-with-callback and withdraw when rewards are nonzero.
  - If vault uses `nativeBalanceLastKnown` to detect “donations” or “skim”, check whether an attacker can donate assets to manipulate share price and then withdraw more than fair value.
- Review focus:
  - A5: Are `totalDeposited` and `nativeBalanceLastKnown` reconciled to actual underlying `balanceOf` at end, and how does it behave with fee-on-transfer / rebasing (balance change without transfer)?
  - Reentrancy: during `super._withdraw` asset transfer, can underlying token callback reenter vault and manipulate rewards/withdraw again before `nativeBalanceLastKnown` finalization?
  - Does `accrueRewards(owner, receiver)` update *both* owner’s checkpoints and receiver’s (if receiver differs) in a way that cannot be exploited to redirect rewards?
  - If unstaking delay is enforced, does `_withdraw` actually transfer to `UnstakingManager` instead of receiver directly? If so, verify receiver cannot bypass delay.

### `StakingVault.depositAndDelegate(uint256 assets)` / `depositAndDelegate(uint256 assets, address delegatee, address optimisticDelegatee)`
- Priority: high
- Support tier: primary
- Combines capital entry (minting shares) with governance delegation side effects; creates a multi-action state transition that is easy to get ordering wrong.
- If delegation updates can be front-run/reentered around deposit, user can end up with wrong delegate or manipulate vote power snapshots.
- Observed from code:
  - Both overloads exist in `StakingVault.sol` (~lines 184-188).
  - Public overload performs `shares = deposit(assets, msg.sender);` then `_delegate(...)` and `_delegateOptimistic(...)`.
- Flow:
  - User calls `depositAndDelegate(assets)` → forwards to `depositAndDelegate(assets, msg.sender, msg.sender)`.
  - Calls `shares = deposit(assets, msg.sender)` (ERC4626 deposit: transfer underlying in, mint shares).
  - Calls `_delegate(msg.sender, delegatee)` then `_delegateOptimistic(msg.sender, optimisticDelegatee)` (external effects likely in voting modules; may emit delegation events).
- Inferred risks:
  - Multi-action entrypoints often break invariant assumptions in downstream systems that expect delegation changes and stake changes to be separate and ordered deterministically around snapshots.
- Review hypotheses:
  - Confirm vote power is derived from vault share balance, and delegation checkpoints are updated after shares mint; add tests for governance proposal snapshots around a `depositAndDelegate` in same block.
- Review focus:
  - A5: Does `deposit` use pre/post-balance to compute shares? If underlying is fee-on-transfer, minted shares may exceed received assets (loss to vault).
  - Reentrancy: if underlying transfer has callback, can attacker reenter between `deposit` and `_delegate*` to alter delegate identity or snapshot assumptions?
  - Do delegation calls touch external contracts (governance token) or purely internal checkpoints? If external, ensure no reentrancy back into vault accounting.
  - If `_delegateOptimistic` maps to optimistic governor throttling identity, can a user deposit then delegate to bypass per-proposer throttle semantics (A4)?

## Rewards allowlist and authority: RewardTokenRegistry (A7)

### `RewardTokenRegistry.registerRewardToken(address rewardToken)`
- Priority: high
- Support tier: primary
- Defines the authoritative allowlist of reward tokens; if compromised, attacker can list a malicious token to brick claims or siphon accounting assumptions.
- This registry is an external policy dependency for StakingVault reward logic (A7).
- Observed from code:
  - `registerRewardToken` is `external` and checks `roleRegistry.isOwner(msg.sender)` in `contracts/staking/RewardTokenRegistry.sol` (~line 35).
  - Uses `EnumerableSet.AddressSet _rewardTokens` and `add` must return true else reverts `RewardAlreadyRegistered`.
- Flow:
  - Caller invokes `registerRewardToken(rewardToken)`.
  - Checks `roleRegistry.isOwner(msg.sender)`.
  - Checks `rewardToken != address(0)` and adds to `EnumerableSet`.
  - Emits `RewardTokenRegistered(rewardToken)`.
- Inferred risks:
  - Registry-driven loops over reward tokens are a common DoS surface: one bad token can block reward settlement for everyone.
  - Owner-only listing means compromise of owner keys or RoleRegistry bug is immediate reward policy compromise.
- Review hypotheses:
  - Confirm StakingVault uses a bounded list and can tolerate large registries (gas grief). If it iterates over registry values on every accrue/claim, listing many tokens can DoS core flows.
- Review focus:
  - A7: Does StakingVault consult this registry on *every* path that (a) funds rewards, (b) updates reward indices, and (c) transfers rewards? Or can an unregistered token still be claimed if it’s already in internal mappings?
  - What happens to accrued rewards when a token is unregistered? Are they still claimable, or is there a forced forfeiture? Ensure conservation + non-DoS.
  - If a malicious/reverting ERC20 is registered, can it permanently brick `accrueRewards` loops for all users (global DoS)? Is there an emergency delist-and-skip mechanism?
  - Is `roleRegistry` itself timelock-governed and resistant to capture? Registry access control is only as strong as RoleRegistry.

### `RewardTokenRegistry.unregisterRewardToken(address rewardToken)`
- Priority: high
- Support tier: primary
- Emergency/configuration escape hatch to remove bad reward tokens; critical for DoS containment when tokens revert on transfer.
- Delisting semantics must not break reward conservation or strand already-accrued rewards unexpectedly (A6/A7).
- Observed from code:
  - `unregisterRewardToken` is `external` and gated by `isOwnerOrEmergencyCouncil` in `RewardTokenRegistry.sol` (~line 44).
  - Uses `EnumerableSet.remove` and emits `RewardTokenUnregistered`.
- Flow:
  - Caller invokes `unregisterRewardToken(rewardToken)`.
  - Checks `roleRegistry.isOwnerOrEmergencyCouncil(msg.sender)`.
  - Removes token from `EnumerableSet` else reverts.
  - Emits `RewardTokenUnregistered(rewardToken)`.
- Inferred risks:
  - Delisting without a migration path can permanently lock funds if vault requires “token must be registered to claim” (conservation breach via unclaimable balances).
- Review hypotheses:
  - Inspect vault claim/fund functions: do they check registry membership at transfer time? Add tests for unregister-then-claim and claim-then-unregister in same block.
- Review focus:
  - A7/A6: After unregistering, does vault stop accruing further rewards but still allow claiming already-accrued amounts? Or does it zero them? Define and test the intended invariant.
  - Can EmergencyCouncil remove a token mid-claim to grief users (e.g., revert by causing mismatch with vault state)?
  - If vault caches registry membership at init, unregister may not take effect. Ensure vault consults registry dynamically or has a safe sync mechanism.

## Factory / supply-chain surfaces: deterministic deployers and library linking (A8)

### `ReserveOptimisticGovernanceVersionRegistryDeployer.deploy(address roleRegistry, bytes32 salt)`
- Priority: high
- Support tier: primary
- CREATE2-style deployment of a VersionRegistry instance; wrong args or salt reuse can place different code at expected addresses (integrator trust issue).
- Version registry is a supply-chain root: controls what implementations/versions are considered valid downstream (A8).
- Observed from code:
  - `deploy(address _roleRegistry, bytes32 salt)` is `internal` in `contracts/artifacts/ReserveOptimisticGovernanceVersionRegistryDeployer.sol` (~line 18).
  - Uses `abi.encodePacked(initcode(), args)` then `DeployHelper.deploy(initcode_, salt)`.
- Flow:
  - ABI-encodes constructor args: `args = abi.encode(roleRegistry)`.
  - Builds initcode: `initcode_ = abi.encodePacked(initcode(), args)`.
  - Calls `DeployHelper.deploy(initcode_, salt)` (expected CREATE2).
  - Returns `deployed` address.
- Inferred risks:
  - Artifact-based deployers bypass Solidity compiler visibility into linked libraries and can embed unexpected bytecode; auditors must treat initcode as source of truth.
- Review hypotheses:
  - Verify that the initcode corresponds to `contracts/VersionRegistry.sol` and that its access control matches the protocol’s trust model (owner/timelock).
- Review focus:
  - A8: Does `DeployHelper.deploy` revert if already deployed at that salt, or can it be replayed/selfdestruct-redeployed? Ensure deterministic uniqueness assumptions.
  - Is `roleRegistry` validated nonzero in the deployed contract constructor (bytecode suggests a zero-address check exists)?
  - Is the initcode blob exactly the audited VersionRegistry? (Artifact deployers can drift from source; ensure hash/bytecode matches).
  - Are there any privileged methods on VersionRegistry that can mutate versions post-deploy without timelock/owner checks?

### `ReserveOptimisticGovernorDeployer.deploy(bytes32 salt)` (library linking + deployment)
- Priority: high
- Support tier: primary
- Deploys the governor implementation with separately deployed libraries (proposal/throttle). Library-address mislinking is an integrity risk: you may deploy bytecode with unexpected throttle/proposal semantics.
- This is a critical supply-chain step because governor logic governs timelock execution rights (A1/A4/A8).
- Observed from code:
  - `deploy(bytes32 salt)` is `internal` in `contracts/artifacts/ReserveOptimisticGovernorDeployer.sol` (~line 18).
  - Explicitly deploys two libraries and passes their addresses into `initcode(throttleLib, proposalLib)`.
- Flow:
  - Deploys `proposalLib = DeployHelper.deployLibrary(_proposalLibInitcode())`.
  - Deploys `throttleLib = DeployHelper.deployLibrary(_throttleLibInitcode())`.
  - Builds governor initcode with both library addresses: `initcode(throttleLib, proposalLib)`.
  - Deploys via `DeployHelper.deploy(initcode_, salt)`.
- Inferred risks:
  - Library deployment is an additional attack surface compared to monolithic bytecode; any compromise changes core governance invariants while keeping high-level API the same.
- Review hypotheses:
  - Identify and review the actual throttle/proposal library source and ensure it matches the initcode in this artifact (bytecode drift risk).
- Review focus:
  - A8: Are deployed library addresses deterministic/verified? If attacker can influence or replace libs, governor’s security assumptions (A3/A4) can be altered without changing governor address expectations.
  - Does `deployLibrary` prevent deploying a different library at same address (CREATE2 salt collisions)?
  - Confirm the governor implementation is intended to be used behind a proxy; does this deployer deploy implementation or proxy? If implementation, where is the proxy deployed and initialized?
  - Test: ensure the deployed governor bytecode’s linked library addresses match those returned by this deployer (no unlinked placeholders).

### `ReserveOptimisticGovernorDeployerDeployer.deploy(address versionRegistry, address rewardTokenRegistry, address guardian, address stakingVaultImpl, address governorImpl, address timelockImpl, address selectorRegistryImpl, bytes32 salt)`
- Priority: medium
- Support tier: primary
- Deploys the top-level Deployer contract that wires together registry, guardian, implementations, and selector registry; miswiring here causes systemic misconfiguration across the protocol suite.
- Acts as a “meta-factory” with many authority pointers—high blast radius if args are wrong (A8).
- Observed from code:
  - `deploy(...)` is `internal` in `contracts/artifacts/ReserveOptimisticGovernorDeployerDeployer.sol` (~line 18).
  - Builds initcode via `abi.encodePacked(initcode(), args)` and uses `DeployHelper.deploy`.
- Flow:
  - Encodes args for Deployer constructor.
  - Deploys with `DeployHelper.deploy(abi.encodePacked(initcode(), args), salt)`.
  - Deployed Deployer then expected to deploy/proxy-initialize governor/vault/timelock/selector-registry instances (not visible in artifact snippet).
- Inferred risks:
  - Meta-factories are common sources of “uninitialized instance” bugs: factory deploys proxy but forgets to call initialize, leaving public initializer open.
- Review hypotheses:
  - Locate the Deployer source (`contracts/Deployer.sol` referenced in comment) and confirm it initializes all proxies in the same transaction and sets correct admin/roles to timelock.
- Review focus:
  - A8: Are all passed-in implementation addresses nonzero and code-validated? If an EOA is supplied, initialization could be hijacked via delegatecall/upgrade patterns.
  - Guardian role: what privileges does `_guardian` have (veto/challenge?) and can it bypass timelock? Ensure guardian powers are scoped to optimistic safety only.
  - Selector registry implementation: can it be upgraded/changed to allow arbitrary selectors under optimistic path?
  - Do constructor args get stored immutably or can Deployer later be reconfigured to deploy different implementations under same “trusted” deployer address?

### `StakingVaultDeployer.deploy(bytes32 salt)`
- Priority: medium
- Support tier: primary
- Deterministic deployment of StakingVault bytecode; used to standardize addresses and ensure audited implementation is what gets deployed.
- However, deploying an implementation without atomic proxy initialization can expose initializer takeover (A8).
- Observed from code:
  - `deploy(bytes32 salt)` is `internal` in `contracts/artifacts/StakingVaultDeployer.sol` (~line 18).
  - Uses `DeployHelper.deploy(initcode_, salt)` with initcode returned by `initcode()`.
- Flow:
  - Builds vault initcode via `initcode()` (artifact-embedded bytecode).
  - Deploys via `DeployHelper.deploy(initcode_, salt)`.
- Inferred risks:
  - CREATE2 deterministic addresses are predictable; if factory doesn’t deploy first on a chain, an attacker can deploy at same salt if they control deployer address context (rare but relevant for cross-chain).
- Review hypotheses:
  - Verify if `DeployHelper` uses CREATE2 from a fixed deploying address; if not, deterministic address guarantees may be weaker than assumed.
- Review focus:
  - A8: Is this deployer deploying an *implementation* or a *proxy*? If implementation, ensure it’s never used as-is and is initialized/locked appropriately.
  - If proxies are used elsewhere: confirm proxy points to the deployed implementation and `initialize` is called immediately.
  - Bytecode drift: ensure artifact initcode matches `contracts/staking/StakingVault.sol` compiled version and linked libraries.

### `RewardTokenRegistryDeployer.deploy(address roleRegistry, bytes32 salt)`
- Priority: medium
- Support tier: primary
- Deterministic deployment of RewardTokenRegistry; sets the allowlist authority root via RoleRegistry.
- If RoleRegistry address is wrong, reward allowlist control is lost (A7/A8).
- Observed from code:
  - `deploy(address _roleRegistry, bytes32 salt)` is `internal` in `contracts/artifacts/RewardTokenRegistryDeployer.sol` (~line 18).
  - Uses `DeployHelper.deploy` with initcode+args.
- Flow:
  - Encodes args: `abi.encode(roleRegistry)`.
  - Deploys `initcode_ = abi.encodePacked(initcode(), args)` via `DeployHelper.deploy`.
- Inferred risks:
  - If different environments deploy different RoleRegistry, deterministic registry address is not sufficient; integrators must verify constructor args.
- Review hypotheses:
  - Confirm whether registry constructor enforces nonzero roleRegistry (source shows it does) and whether deployer passes correct roleRegistry in all deployment scripts.
- Review focus:
  - A8: Ensure the RoleRegistry address is correct and immutable; registry access control depends entirely on it.
  - A7: Verify registry has no hidden admin besides RoleRegistry checks (artifact bytecode review).

## Secondary-support: exploit-family warnings to drive tests (not repo-native entrypoints)

### `Exploit-family warning: vault share accounting under non-standard ERC20s (fee-on-transfer / rebasing / ERC777 callbacks)`
- Priority: medium
- Support tier: secondary_support
- Historical vault losses often come from assuming `assets == transferred` and `totalAssets == balanceOf` without accounting for transfer fees or rebases.
- Use this to design adversarial token tests against `deposit`, `_withdraw`, and reward settlement ordering.
- Observed from code:
  - Repo shows explicit `nativeBalanceLastKnown` tracking and mentions reconciliation at bottom of `_withdraw` (suggests awareness but needs proof via tests).
- Flow:
  - Adversarial underlying token charges transfer fee → deposit mints shares as if full assets received → share price drifts → later withdraw drains honest users.
  - Rebasing underlying changes `balanceOf(vault)` without vault action → `nativeBalanceLastKnown`/`totalDeposited` may diverge → share conversion functions become manipulable.
  - ERC777-style callbacks reenter during transfer in/out → can call back into vault before checkpoints are updated.
- Inferred risks:
  - Even with explicit balance tracking, corner cases appear when both rewards and underlying are transferred in the same call stack (reward token transfer failure can revert and lock withdrawals).
- Review hypotheses:
  - Add Foundry property tests with mock fee-on-transfer + mock rebasing token; assert A5 under sequences of deposit/withdraw/donate/rebase.
- Review focus:
  - Does vault compute shares based on actual received assets (post-transfer balance delta) rather than requested `assets`?
  - Are reentrancy guards present around deposit/withdraw/claim flows that do external transfers?
  - If `nativeBalanceLastKnown` is used as an anti-donation mechanism, can an attacker force it out of sync and arbitrage share pricing?
