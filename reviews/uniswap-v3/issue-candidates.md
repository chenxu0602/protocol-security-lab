# Issue Candidates

## Candidate 1: Tick crossing directionality may misapply `liquidityNet` under `zeroForOne`
### Category
Core accounting / swap state machine

### Priority
High

### Observation
During `swap()`, the pool calls `ticks.cross(...)` and then conditionally negates the returned `liquidityNet` when moving leftward under `zeroForOne`.

This is a high-friction area because:
- tick-side `liquidityNet` is stored with lower/upper boundary sign conventions
- swap-direction handling inverts meaning again when crossing in the opposite direction
- active liquidity must change exactly once and with the correct sign

### Why It Matters
If `liquidityNet` is applied with the wrong sign on crossing, active liquidity becomes wrong for all later swap steps and fee attribution.

### Potential Impact
- swaps may execute against too much or too little active liquidity
- LP fees may be misallocated across adjacent ranges
- price movement may deviate from intended bounds

### Related Invariants
- Active liquidity must equal current in-range liquidity, not total position liquidity.
- Tick boundary state must encode range effects correctly.
- Tick crossing must flip outside accumulators without losing total cumulative meaning.

### Status
Strong candidate.  
Not a confirmed issue; this is a primary correctness surface to validate aggressively.

### How I Would Validate It
- Create adjacent and overlapping positions around one or two initialized ticks
- Swap left-to-right across a tick, then right-to-left back across the same tick
- Check active liquidity before and after each crossing
- Compare owed fees and post-swap price against expected range activity

---

## Candidate 2: `feeGrowthInside` reconstruction may fail around boundary conditions at `tickLower` / `tickUpper`
### Category
Core accounting / LP fee attribution

### Priority
High

### Observation
`Tick.getFeeGrowthInside()` depends on branch logic that interprets lower and upper tick outside accumulators differently depending on whether `currentTick` is:
- below the range
- inside the range
- above the range

This is especially easy to get wrong exactly at boundary conditions because lower uses `>=` logic while upper uses `<` logic.

### Why It Matters
All lazy position fee settlement flows depend on reconstructing inside fee growth correctly from current/global state plus lower/upper outside values.

### Potential Impact
- positions may under-accrue or over-accrue fees
- fee crystallization may differ depending on whether a user updates just before or just after a boundary crossing
- out-of-range positions may incorrectly lose previously earned fees

### Related Invariants
- Fee growth inside a range must be reconstructible from global and lower/upper outside state.
- A position’s `tokensOwed` must only reflect crystallized entitlement.

### Status
Strong candidate.  
Very plausible review target in any concentrated-liquidity accounting system, but not a confirmed flaw here.

### How I Would Validate It
- Mint a single position around the current tick
- Generate fees while price is below range, inside range, and above range
- Trigger crystallization with `burn(0)` and compare outcomes across the three regimes
- Repeat at exact lower-boundary and upper-boundary ticks

---

## Candidate 3: Per-step fee attribution may become inconsistent with pre-cross active liquidity at initialized tick boundaries
### Category
Swap math / fee accounting

### Priority
High

### Observation
In `swap()`, per-step fee growth is updated before any later initialized-tick crossing changes active liquidity for the next step.

That ordering looks intentional, but it is a place where an implementation bug would be subtle:
- fee for the current step should belong only to liquidity active during that step
- crossing should affect only subsequent steps

### Why It Matters
If step fees are applied using post-crossing liquidity or the wrong token-side global fee tracker, LPs in neighboring ranges can capture fees they did not earn.

### Potential Impact
- misallocation of fees between positions
- measurable divergence in `tokensOwed` across ranges after cross-tick swaps
- unfair fee capture by LPs whose liquidity was inactive during the step

### Related Invariants
- Swap fees must be attributed only to liquidity active during that step.
- Protocol fees must remain disjoint from LP fee growth.

### Status
Strong candidate.  
This is a classic concentrated-liquidity accounting edge, but no flaw is asserted yet.

### How I Would Validate It
- Create two positions with disjoint neighboring ranges
- Run swaps that end exactly on an initialized tick and swaps that cross it
- Compare fee accrual between positions for same-direction and reverse-direction swaps
- Confirm only the liquidity active during each step receives that step’s LP fee share

---

## Candidate 4: `collect()` does not itself crystallize newly accrued fees, which may create stale-balance assumptions in integrations
### Category
Integration / accounting interface risk

### Priority
Integration / Intended behavior review

### Observation
`collect()` only withdraws already-crystallized `tokensOwed`; it does not itself update fee checkpoints.

Integrators or wrappers may assume:
- `collect()` always realizes all fees up to now
- no prior `burn(0)` / liquidity-changing action is needed

### Why It Matters
Even if core behavior is correct, misunderstanding this interface can create stale-accounting integrations, misleading UI balances, or wrappers that under-collect.

### Potential Impact
- users may receive less than expected in wrapper flows
- integrators may misreport claimable fees
- tests written against incorrect expectations may hide real bugs elsewhere

### Related Invariants
- A position’s `tokensOwed` must only reflect crystallized entitlement.

### Status
Likely intended behavior, but important integration-risk candidate.

### How I Would Validate It
- Accrue fees on a live position
- Call `collect()` without `burn(0)` or liquidity update
- Observe whether newly accrued fees remain uncollected
- Then call `burn(0)` and `collect()` again to confirm the intended two-step flow

---

## Candidate 5: Observation cardinality growth may be misinterpreted as immediately usable oracle depth
### Category
Oracle / historical data correctness

### Priority
Integration / Intended behavior review

### Observation
Observation capacity growth is decoupled from observation writes:
- `increaseObservationCardinalityNext()` raises future capacity
- actual population of new slots only happens through later writes during swaps

Consumers may incorrectly assume that increasing cardinality immediately creates deeper usable history.

### Why It Matters
Oracle consumers rely on ordered, sufficiently deep cumulative history. Freshly grown but not yet populated slots can create misunderstood coverage assumptions.

### Potential Impact
- TWAP consumers may request historical points older than populated observation history
- integrations may treat newly increased cardinality as immediately usable depth
- edge-case reads may revert with `OLD` or behave unexpectedly to integrators

### Related Invariants
- Oracle observations must remain ordered and support correct cumulative differencing.
- Range-inside cumulative reconstruction must match current tick location.

### Status
Likely intended oracle behavior, but high-value integration and review candidate.

### How I Would Validate It
- Initialize a pool with minimal observation history
- Increase `observationCardinalityNext`
- Immediately request older observations before enough swaps have populated new slots
- Confirm actual usable depth vs perceived configured depth

---

## Candidate 6: `snapshotCumulativesInside()` may be misused as position-history reconstruction across liquidity lifecycle changes
### Category
Oracle / analytics misuse risk

### Priority
Integration / Intended behavior review

### Observation
`snapshotCumulativesInside()` returns range-level cumulative snapshots, not full historical position state.

If a position is minted, burned, or liquidity-adjusted between two snapshots, subtracting the snapshots does not by itself reconstruct:
- historical `tokensOwed`
- historical inventory
- historical position-level fee state

### Why It Matters
Review tooling or analytics built on the wrong assumption can infer false bugs or miss real ones.

### Potential Impact
- incorrect LP analytics
- bad off-chain accounting or monitoring
- false confidence in historical fee reconstruction

### Related Invariants
- Range-inside cumulative reconstruction must match current tick location.
- A position’s `tokensOwed` must only reflect crystallized entitlement.

### Status
Likely intended behavior, but important review and analytics candidate.

### How I Would Validate It
- Take inside snapshots around a range
- Change position liquidity between snapshots
- Compare snapshot differences against actual position fee crystallization
- Confirm divergence between range analytics and position accounting

---

## Candidate 7: Flash overpayment is accrued as fee-like value to LPs/protocol based on actual paid amounts
### Category
Economic accounting / flash path

### Priority
Integration / Intended behavior review

### Observation
`flash()` validates minimum repayment but accrues fee growth and protocol fees based on actual amounts paid above pre-flash balances, not merely on quoted fee amounts.

That means callback overpayment becomes fee-like value for LPs/protocol.

### Why It Matters
This may be intended, but it is economically meaningful and easy to miss when reasoning about flash-fee distribution.

### Potential Impact
- overpayment in a flash callback may be irrecoverably donated to LPs/protocol
- integrators may misunderstand how extra repayment is accounted for
- protocol fee share may apply to more than the nominal fee quote

### Related Invariants
- Flash fee accrual must be based on actual paid amounts.
- Protocol fees must remain disjoint from LP fee growth.

### Status
Likely intended accounting behavior, but worth validating explicitly.

### How I Would Validate It
- Execute a flash with exact repayment plus fee
- Execute another flash with deliberate overpayment
- Compare LP fee growth and protocol fee deltas between the two runs

---

## Candidate 8: Non-standard ERC20 behavior may violate pool-side balance-check assumptions
### Category
External integration / token-behavior risk

### Priority
Integration / Out-of-scope risk

### Observation
Core settlement relies on token balance checks around external callbacks and token transfers.

Non-standard token behavior such as:
- fee-on-transfer
- rebasing during the transaction
- callback-sensitive balance changes

may break the intended interpretation of pre/post balances.

### Why It Matters
Uniswap V3 core assumes sufficiently well-behaved ERC20 semantics. Exotic tokens can still create integration hazards even if the core implementation is sound for standard tokens.

### Potential Impact
- mints/swaps/flash calls may revert unexpectedly
- accounting assumptions about actual amounts moved may fail
- integrators may incorrectly treat unsupported tokens as safe

### Related Invariants
- Callback-based settlement must leave the pool fully paid.
- `slot0` must always describe a self-consistent current execution state.

### Status
Likely out of scope for canonical core correctness, but critical integration-risk candidate.

### How I Would Validate It
- Use fee-on-transfer or rebasing token mocks in mint/swap/flash paths
- Compare actual token movement to pool-expected deltas
- Confirm whether failures are safe reverts or produce accounting drift

---

## Candidate 9: Protocol-fee configuration changes near active trading may create edge-case attribution misunderstandings
### Category
Governance / fee accounting

### Priority
Medium

### Observation
`setFeeProtocol()` changes how input-side swap fees are split between protocol and LPs going forward, while previously accrued fee growth and protocol fees remain stored separately.

This area is subtle because:
- the setting is token-side packed into `slot0`
- swap direction chooses which half applies
- the change should affect only future accrual

### Why It Matters
If fee-protocol packing/unpacking or directional application is wrong, protocol may over-collect or LPs may be shortchanged on one side.

### Potential Impact
- asymmetric protocol fee extraction across token0/token1 directions
- incorrect LP fee growth on one swap direction
- governance configuration producing unexpected fee outcomes

### Related Invariants
- Protocol fees must remain disjoint from LP fee growth.
- `slot0` must always describe a self-consistent current execution state.

### Status
Targeted review candidate.  
No issue asserted, but worth directional testing.

### How I Would Validate It
- Run swaps in both directions with protocol fee off
- Turn protocol fee on for one or both sides
- Repeat the same swap patterns
- Compare protocol-fee and LP-fee attribution across directions

---

## Candidate 10: Position token decomposition may be wrong exactly at regime transitions
### Category
Position accounting / price-boundary math

### Priority
High

### Observation
Position updates decompose liquidity changes into token0-only, token1-only, or mixed token requirements depending on whether the current price is:
- below range
- in range
- above range

Boundary equality cases are easy to mishandle because they depend on precise tick/sqrt-price conventions.

### Why It Matters
If token decomposition is wrong at regime transitions, mint/burn amounts can be off exactly where concentrated-liquidity positions are most sensitive.

### Potential Impact
- LPs may be asked for the wrong token mix
- burn proceeds may be mis-credited
- wrappers around position management may misprice deposits/withdrawals

### Related Invariants
- Position inventory decomposition must match current price regime.
- Price movement must never overshoot the chosen target boundary or user limit.

### Status
Strong candidate.  
This is a primary math/accounting surface to validate aggressively.

### How I Would Validate It
- Mint and burn positions with current price strictly below range, strictly in range, and strictly above range
- Repeat at exact boundary ticks and with tiny movements across the boundary
- Compare required token amounts and returned token deltas against expected regime decomposition