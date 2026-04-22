# Uniswap V3 Simulation Engine Plan

`uniswap-sim` is a Python-driven research simulation engine for Uniswap V3.
It uses Solidity contracts as the source of truth and treats Python as the
orchestration layer for batch scenario execution, structured metrics, and
replayable analysis.

This is not a replacement for Foundry.

Foundry remains responsible for:

- protocol semantics
- unit tests
- invariant tests
- regression tests
- boundary and decomposition correctness

The simulation engine answers a different class of questions:

- What happens across many scenario realizations?
- How do fee capture, inventory drift, and PnL behave under different liquidity layouts?
- How sensitive are outcomes to path dependence, fragmentation, or adversarial flow?
- Which strategies outperform after repeating the same scenario class many times?

The guiding rule is simple:

**Solidity defines truth. Python explores the scenario space.**

## Core Terms

`spec`

Defines what to run.

`runner`

Translates a scenario into a concrete sequence of onchain actions.

`worker`

Executes one isolated scenario instance.

`metrics`

Transforms raw execution traces into structured outputs.

`store`

Persists raw and summarized results for replay and analysis.

## Project Layout

```text
uniswap-sim/
  specs/
    boundary_pinning.yaml
    cross_reverse.yaml
    liquidity_grid.yaml

  engine/
    scheduler.py
    runner.py
    metrics.py
    state.py
    adapters/
      moccasin.py
      foundry.py

  strategies/
    trader.py
    lp.py
    attacker.py

  datasets/
    fixtures/
    outputs/

  reports/
    notebook/
    summary.md
```

## Responsibility Boundaries

### `specs/`

Describes what should be simulated.

Should contain:

- scenario configuration
- pool setup
- actor configuration
- metric selection
- seeds and repetitions

Should not contain execution logic.

### `engine/runner.py`

Describes how actions are executed in order.

Should:

- load a scenario
- initialize actors
- call the adapter
- record step results

Should not own persistence or scheduling logic.

### `engine/scheduler.py`

Describes how multiple scenario instances are distributed.

Should:

- allocate work to workers
- manage task-level parallelism
- collect results

Should not interpret protocol logic.

### `engine/metrics.py`

Describes how results are computed.

Should:

- compute common metrics
- compute scenario-specific metrics
- produce structured summaries

Should not send transactions.

### `strategies/`

Describes participant behavior.

Examples:

- passive LP
- boundary pinning attacker
- directional trader
- cross-reverse farmer

### `datasets/`

Stores:

- raw step logs
- final summaries
- fixtures
- replay data

### `reports/`

Contains:

- notebooks
- charts
- written summaries
- comparison reports

## Scenario Model

A scenario should describe:

- initial state
- participant behavior
- execution horizon
- metrics of interest

### Suggested Minimum Schema

`ScenarioSpec`

- `name`
- `seed`
- `chain_config`
- `pool_config`
- `initial_state`
- `lp_layout`
- `trader_flow`
- `attacker_strategy`
- `time_horizon`
- `repetitions`
- `metrics`

### Field Meanings

`name`

Human-readable scenario identifier.

`seed`

Random seed for reproducibility.

`chain_config`

Execution backend and chain-level parameters.

Examples:

- local fork
- block number
- gas assumptions
- backend selection

`pool_config`

Uniswap pool configuration.

Examples:

- token pair
- fee tier
- tick spacing
- initial price
- liquidity bootstrap

`initial_state`

Starting state before actions begin.

Examples:

- initial tick
- observation/cardinality settings
- existing liquidity state

`lp_layout`

Initial LP placement.

Examples:

- wide symmetric
- narrow range
- layered grid
- one-sided concentration

`trader_flow`

Action sequence or trader policy.

Examples:

- swap direction distribution
- notional size distribution
- bursty flow
- random walk flow

`attacker_strategy`

Optional adversarial strategy.

Examples:

- boundary pinning
- cross-reverse farming
- JIT liquidity
- decomposition exploitation

`time_horizon`

Number of steps or cycles to run.

`repetitions`

How many independent instances to execute.

`metrics`

Which outputs should be computed.

## YAML Schema Draft

This is the minimal shape I would start with.

```yaml
name: boundary_pinning
seed: 42

chain_config:
  backend: moccasin
  fork_url: null
  block_number: null
  gas_price: auto

pool_config:
  token0: USDC
  token1: WETH
  fee_tier: 3000
  tick_spacing: 60
  initial_price: 1.0
  liquidity_bootstrap: 1000000000000000000

initial_state:
  initial_tick: 0
  observation_cardinality: 1
  observation_cardinality_next: 1
  existing_liquidity: []

lp_layout:
  - actor: victim_lp
    kind: wide_symmetric
    lower_tick: -600
    upper_tick: 600
    liquidity: 2000000000000000000
  - actor: attacker_lp
    kind: narrow_boundary
    lower_tick: 0
    upper_tick: 60
    liquidity: 2000000000000000000

trader_flow:
  kind: bursty_boundary_flow
  steps: 200
  size_distribution:
    kind: fixed
    value: 100000000000000000
  direction_distribution:
    kind: alternating

attacker_strategy:
  kind: boundary_pinning
  target_lower_tick: 0
  target_upper_tick: 60
  entry_policy: always_on_boundary

time_horizon:
  steps: 200
  cycles: 20

repetitions: 32

metrics:
  - fee_capture_by_actor
  - realized_pnl
  - inventory_drift
  - gas_used
  - boundary_hit_rate
  - cross_count
```

### Schema Notes

- `chain_config.backend` should identify the execution adapter.
- `pool_config` should only describe the target pool, not execution behavior.
- `initial_state` should capture any state that must exist before the first action.
- `lp_layout` should define actor positions, not strategy logic.
- `trader_flow` and `attacker_strategy` are policy objects, not static setup.
- `metrics` should be explicit so each run knows what to compute.

## Output Schema Drafts

The engine should emit two levels of structured output.

### `StepRecord`

This is the replay and debugging unit.

```yaml
step_id: 0
scenario_name: boundary_pinning
seed: 42

action:
  action_type: swap
  actor: trader_1
  direction: zero_for_one
  amount_specified: 100000000000000000

state_before:
  tick: 54
  sqrt_price_x96: 79228162514264337593543950336

state_after:
  tick: 59
  sqrt_price_x96: 79232123823359799118286999567

effects:
  fee_delta:
    actor_1: 1234
    actor_2: 0
  inventory_delta:
    actor_1: -100000000000000000
    actor_2: 0
  gas_used: 185000
  revert_flag: false

trace:
  tx_hash: null
  state_hash: 0xabc123
```

Fields to keep stable:

- `step_id`
- `scenario_name`
- `seed`
- `action.action_type`
- `action.actor`
- `state_before.tick`
- `state_after.tick`
- `effects.fee_delta`
- `effects.inventory_delta`
- `effects.gas_used`
- `effects.revert_flag`
- `trace.state_hash`

### `ScenarioResult`

This is the aggregation unit.

```yaml
scenario_name: boundary_pinning
seed: 42

final_state:
  final_tick: 59
  final_sqrt_price_x96: 79232123823359799118286999567

summary:
  total_fee_capture_by_actor:
    victim_lp: 120000
    attacker_lp: 154000
  total_realized_pnl:
    victim_lp: -80000
    attacker_lp: 16000
  total_inventory_drift:
    victim_lp: 0
    attacker_lp: -20000000000000000
  total_gas: 4200000
  boundary_hit_rate: 0.63
  cross_count: 18

metadata:
  repetitions: 32
  path_id: boundary_pinning-42
  revert_rate: 0.0
```

Fields to keep stable:

- `scenario_name`
- `seed`
- `final_state.final_tick`
- `final_state.final_sqrt_price_x96`
- `summary.total_fee_capture_by_actor`
- `summary.total_realized_pnl`
- `summary.total_inventory_drift`
- `summary.total_gas`
- `summary.boundary_hit_rate`
- `summary.cross_count`

## Backends

The backend is an adapter detail.

The first backend can be Moccasin.
The design should still allow a later swap to other EVM runners.

### Adapter Rules

The adapter layer should be thin.

It should:

- deploy or load contracts
- send transactions
- query contract state
- decode events and receipts
- manage snapshots and reverts

It should not:

- interpret protocol economics
- reimplement Uniswap math
- own scenario logic
- own aggregation

## Scheduler Notes

The scheduler should only manage task distribution.

It should:

- expand one `ScenarioSpec` into many scenario instances
- assign instances to workers
- collect worker outputs
- handle retries and failures

It should not:

- inspect tick math
- decide LP layouts
- compute fee attribution
- store domain metrics directly

## Minimal File Responsibilities

When the project moves from design to code, these files should stay narrow:

- `engine/runner.py` defines execution order
- `engine/scheduler.py` defines work distribution
- `engine/metrics.py` defines output derivation
- `engine/adapters/moccasin.py` defines EVM transport
- `engine/state.py` defines local execution state and snapshots
- `strategies/*.py` defines participant behavior

## Local Repo Placement

This plan and later drafts should stay inside:

`evm-playground/uniswap-foundry/`

That keeps the documentation adjacent to the Uniswap harness, scripts, and
future prototype code.

## Engine Module Sketch

The engine package should stay small and explicit.

### `engine/state.py`

Responsibilities:

- hold per-worker execution state
- store the active scenario
- track snapshots and rollback points
- expose the latest onchain state summary

Possible interface sketch:

```python
class WorkerState:
    scenario: ScenarioSpec
    snapshot_id: str | None
    current_step: int

    def snapshot(self) -> str: ...
    def revert(self, snapshot_id: str) -> None: ...
    def update(self, step_record: StepRecord) -> None: ...
```

### `engine/adapters/moccasin.py`

Responsibilities:

- deploy or load contracts
- send transactions
- query contract state
- decode logs and receipts
- manage local snapshots

Possible interface sketch:

```python
class MoccasinAdapter:
    def setup(self, spec: ScenarioSpec) -> None: ...
    def execute_action(self, action: dict) -> StepRecord: ...
    def read_state(self) -> dict: ...
    def snapshot(self) -> str: ...
    def revert(self, snapshot_id: str) -> None: ...
```

### `engine/adapters/foundry.py`

Responsibilities:

- provide an alternate backend shape for local execution
- keep the adapter contract stable across backends

This file can stay thin at first and only mirror the Moccasin adapter shape.

### `engine/runner.py`

Responsibilities:

- load a `ScenarioSpec`
- initialize actor policies
- translate policies into actions
- call the adapter in order
- collect `StepRecord` objects

Possible interface sketch:

```python
class ScenarioRunner:
    def __init__(self, adapter, metrics): ...
    def run(self, spec: ScenarioSpec) -> ScenarioResult: ...
    def run_step(self, action: dict) -> StepRecord: ...
```

### `engine/scheduler.py`

Responsibilities:

- expand one spec into many scenario instances
- distribute work across processes
- collect results from workers
- report failures and retries

Possible interface sketch:

```python
class Scheduler:
    def submit(self, spec: ScenarioSpec) -> None: ...
    def run(self) -> list[ScenarioResult]: ...
    def collect(self) -> list[ScenarioResult]: ...
```

### `engine/metrics.py`

Responsibilities:

- derive common metrics
- derive scenario-specific metrics
- aggregate step records into summary results

Possible interface sketch:

```python
class MetricsEngine:
    def compute_step_metrics(self, step: StepRecord) -> dict: ...
    def compute_scenario_metrics(self, steps: list[StepRecord]) -> ScenarioResult: ...
```

## Strategy Module Sketch

The strategy layer should define participant behavior only.

### `strategies/trader.py`

Possible responsibilities:

- directional swap flow
- bursty swap flow
- random walk flow

Possible interface sketch:

```python
class TraderPolicy:
    def next_action(self, state: WorkerState) -> dict: ...
```

### `strategies/lp.py`

Possible responsibilities:

- passive LP placement
- layered liquidity grids
- wide symmetric liquidity

Possible interface sketch:

```python
class LPPolicy:
    def build_layout(self, spec: ScenarioSpec) -> list[dict]: ...
```

### `strategies/attacker.py`

Possible responsibilities:

- boundary pinning
- cross-reverse farming
- JIT insertion
- decomposition exploitation

Possible interface sketch:

```python
class AttackerPolicy:
    def next_action(self, state: WorkerState) -> dict: ...
```

## Implementation Order

If this becomes code, the most practical order is:

1. define `ScenarioSpec` and `StepRecord`
2. define `ScenarioResult`
3. implement `MoccasinAdapter`
4. implement `ScenarioRunner`
5. implement `MetricsEngine`
6. implement `Scheduler`
7. add strategy modules

That order keeps the protocol truth on the backend side and avoids building
orchestration before the data model exists.

## Example Scenario Flow

This is the kind of action sequence the runner should generate for a minimal
`boundary_pinning` experiment.

### Scenario Goal

Study how a narrow LP band near a hot boundary captures fees relative to a
wide passive LP under repeated boundary-touching flow.

### Actors

- `victim_lp`
- `attacker_lp`
- `trader`

### Initial Setup

- create a single Uniswap V3 pool
- seed the pool at a known tick
- place one wide passive LP position
- place one narrow boundary LP position
- fund the trader with enough inventory for repeated swaps

### Suggested Action Loop

```text
1. mint victim LP wide range
2. mint attacker LP narrow boundary range
3. trader swaps right toward upper boundary
4. trader swaps left back toward the boundary interior
5. repeat steps 3-4 for N cycles
6. burn or crystallize LP positions
7. collect final balances
8. compute scenario metrics
```

### What the Runner Should Observe

- which LP collected more fees
- how often price touched the boundary band
- whether the attacker achieved higher fee-per-capital
- whether the final inventory drift stayed bounded
- how many directional crossings occurred

### Why This Flow Matters

This is the smallest useful experiment because it produces a distributional
question instead of a boolean question.

It can answer:

- does a narrow band capture a disproportionate share of fee flow?
- how stable is that result across seeds and repeated trials?
- how sensitive is the outcome to small changes in path shape?

## Example Scenario Flow: Cross-Reverse Farming

This scenario studies repeated crossing in both directions around the same
initialized boundary.

### Scenario Goal

Study how fees, inventory drift, and gas cost behave when an attacker places
narrow liquidity on both sides of a hot boundary and forces repeated
cross-and-reverse movement.

### Actors

- `victim_lp`
- `attacker_lp_left`
- `attacker_lp_right`
- `trader`

### Initial Setup

- create one Uniswap V3 pool
- seed the pool at the center tick
- place one wide victim LP position
- place one narrow attacker LP position on the left side
- place one narrow attacker LP position on the right side
- fund the trader for repeated directional swaps

### Suggested Action Loop

```text
1. mint victim wide range
2. mint attacker left narrow range
3. mint attacker right narrow range
4. trader swaps right across the boundary
5. trader swaps left back across the same boundary
6. repeat steps 4-5 for N cycles
7. burn or crystallize all LP positions
8. collect balances
9. compute scenario metrics
```

### What the Runner Should Observe

- how many times the boundary was crossed
- how much fee each LP captured
- whether the attacker recovered more fees than expected from simple TVL share
- how much inventory drift accumulated over the round trips
- how much gas the repeated crossings consumed

### Why This Flow Matters

This scenario is useful because it exposes path dependence.

The same pool state can produce very different outcomes depending on whether
the flow crosses once, reverses, or oscillates around the boundary.

That makes it a better research object than a single-path correctness test.

## Example Scenario Flow: Position Decomposition

This scenario compares how different liquidity layouts decompose into token0
and token1 exposure under the same flow.

### Scenario Goal

Study whether layered or fragmented LP layouts behave differently from a single
aggregated range when the market moves through below-range, in-range, above-
range, and exact-boundary regimes.

### Actors

- `lp_flat`
- `lp_layered`
- `trader`

### Initial Setup

- create one Uniswap V3 pool
- seed the pool at a neutral tick
- place one aggregated LP position
- place one decomposed LP layout made of multiple smaller ranges
- fund the trader with enough inventory for both directions

### Suggested Action Loop

```text
1. mint aggregated LP range
2. mint decomposed LP ranges
3. trader moves price below range
4. trader moves price into range
5. trader moves price above range
6. trader touches exact boundary ticks
7. burn or crystallize positions
8. compare token0/token1 outcomes across layouts
9. compute scenario metrics
```

### What the Runner Should Observe

- how token0 and token1 exposure differ across layouts
- whether the decomposed layout tracks the same regime transitions
- whether fee attribution remains consistent across paths
- how PnL differs under identical flow
- whether boundary behavior changes liquidation or settlement shape

### Why This Flow Matters

This scenario is the cleanest way to compare geometry, not just economics.

It helps answer whether fragmented liquidity behaves like the sum of its parts
or whether boundary transitions create meaningful divergence.

## Worker Model

A worker is the core execution unit.

Each worker should:

- initialize an isolated EVM environment
- deploy or load the required contracts
- execute the scenario action sequence
- record state snapshots and transaction outputs
- emit a structured `ScenarioResult`

### Why This Matters

EVM execution is naturally stateful.

If workers share state, results become:

- hard to reason about
- hard to reproduce
- hard to parallelize safely

The default assumption should be:

`one scenario instance = one worker = one isolated state`

## Parallelism Model

The recommended model is task-level parallelism, not internal scenario parallelism.

### Good Pattern

- one worker runs one scenario instance
- many workers run different instances in parallel
- each worker has isolated state
- one aggregator collects outputs

### Why

This is:

- simpler
- safer
- easier to debug
- easier to scale horizontally

For MVP, local multi-process execution is enough.

A distributed queue can come later if needed.

## Metrics Model

This is where the engine diverges from a standard test suite.

A test framework usually asks:

- Did the assertion pass?

A simulation engine asks:

- What distribution of outcomes did this scenario produce?

### Core Metrics

Every scenario should be able to produce some or all of:

- `final_tick`
- `final_sqrt_price`
- `fee_capture_by_actor`
- `realized_pnl`
- `inventory_drift`
- `gas_used`
- `revert_flag`
- `path_id`
- `seed`

### Metric Definitions

These are the minimum working definitions I would use first.

#### `fee_capture_by_actor`

For each actor, sum the fees crystallized into their position state and any
fees collected at the end of the run.

Use:

- `tokensOwed0`
- `tokensOwed1`
- collect outputs when positions are settled

The output should be recorded per actor and per token, then optionally
normalized into a single value.

#### `realized_pnl`

For each actor, compare ending balance plus unsettled position value against
starting balance and starting inventory.

For a first pass, use:

- initial token balances
- final token balances
- final position state
- a chosen mark price or ending pool price

This metric should stay explicit about the mark-to-market rule being used.

#### `inventory_drift`

Measure how far an actor's net token holdings moved from the starting state.

For a simple version:

- `final_token0 - initial_token0`
- `final_token1 - initial_token1`
- optionally convert to a single signed value using the ending price

This is useful for seeing whether apparent fee gains are just inventory
accumulation.

#### `boundary_hit_rate`

Measure how often price touches or lands on the target boundary band.

For boundary-oriented scenarios:

- count steps where the tick equals the boundary tick
- count steps where the tick lies one spacing inside the target boundary
- divide by total relevant steps or total swaps

This should be defined per scenario so that the numerator and denominator are
clear.

#### `cross_count`

Count how many times the scenario crosses an initialized boundary or changes
side relative to the tracked boundary.

For the first version:

- increment on each swap that changes the active side of the tracked range
- optionally distinguish left-to-right and right-to-left crosses

This metric is the path-dependence signal for `cross_reverse_farming`.

### Extended Metrics

Depending on scenario type:

- `fee_per_capital`
- `profit_per_cycle`
- `max_drawdown`
- `time_underwater`
- `fee_to_inventory_ratio`
- `capital_efficiency`

### Output Levels

#### Step-level record

For replay and debugging.

Suggested fields:

- action index
- actor
- action type
- input params
- pre-tick
- post-tick
- fee delta
- gas used
- revert flag
- state hash

#### Scenario-level result

For aggregation and comparison.

Suggested fields:

- scenario name
- seed
- final state summary
- total fees by actor
- total PnL by actor
- inventory summary
- path statistics

## Storage Strategy

The engine should preserve both:

- raw execution traces
- summarized outputs

### Recommended Format

- `yaml` for scenario specs
- `parquet` for raw step records
- `parquet` or `csv` for scenario summaries

This keeps the workflow friendly for:

- `pandas`
- `polars`
- notebooks
- batch reporting

## Execution Backends

The engine should treat execution as an adapter problem.

### Initial Backend

- Moccasin

### Future Backends

- Foundry-driven local execution
- `anvil`-based workflows
- forked environments
- custom EVM runners

### Design Rule

The adapter should be thin.

It should:

- deploy/load contracts
- send transactions
- query state
- decode receipts/events
- manage snapshots/reverts

It should not reimplement protocol logic.

## Relationship to Foundry

This project should complement Foundry, not compete with it.

### Foundry Responsibilities

- correctness tests
- invariant tests
- protocol semantics
- regression coverage

Examples:

- `BoundaryFeeAdversarial.t.sol`
- `StepFeeAttribution.t.sol`
- `PoolCrossingDirection.t.sol`
- `PositionDecomposition.t.sol`

### Python Simulation Responsibilities

- scenario orchestration
- repeated execution
- structured metrics
- replay and aggregation
- strategy comparison
- statistical analysis

### Design Boundary

Foundry proves semantic correctness.
Python measures scenario behavior.

## Recommended MVP

Start with only three scenario classes:

- `boundary_pinning`
- `cross_reverse_farming`
- `position_decomposition`

These map naturally to existing correctness work while adding research value.

### MVP Sequence

#### Step 1

Define:

- `ScenarioSpec`
- `ScenarioResult`

#### Step 2

Implement one fixed runner for one scenario.

#### Step 3

Implement one worker capable of isolated execution.

#### Step 4

Add metric extraction and structured output.

#### Step 5

Add parallel execution and notebook analysis.

### Suggested MVP v0

The first version should be deliberately small.

Include:

- one pool
- one backend
- one scenario
- one worker
- one result file
- a few core metrics

Exclude:

- generic plugin systems
- multiple AMMs
- distributed infrastructure
- heavy abstractions
- elaborate reporting

### Success Condition

You can run one real Uniswap V3 scenario through Solidity contracts and obtain reproducible structured outputs.

## Example Initial Scenarios

### Boundary Pinning

Goal:

study fee capture and ending tick control near range boundaries

Metrics:

- fee capture by actor
- boundary hit rate
- victim vs attacker fee efficiency
- inventory drift

### Cross-Reverse Farming

Goal:

study repeated cross-and-reverse patterns and fee extraction behavior

Metrics:

- cross count
- fees per cycle
- gas-adjusted profitability
- drift over repeated cycles

### Position Decomposition

Goal:

compare decomposed vs aggregated liquidity structures under identical flow

Metrics:

- fee attribution
- PnL differences
- path sensitivity
- decomposition consistency

## Future Extensions

Possible future work includes:

- replaying historical swap paths
- hybrid synthetic/adversarial trader policies
- richer strategy registries
- automatic report generation
- alternative execution backends
- scenario sweeps over fee tiers and tick spacing
- Panoptic-style overlays on top of Uniswap state

These are intentionally deferred until after the minimal research loop works.

## Development Philosophy

This project should remain:

- narrow
- reproducible
- metrics-first
- backend-agnostic
- Solidity-truthful

If the engine ever requires duplicating core Uniswap semantics in Python, it is moving in the wrong direction.

## Three Block Implementation Plan

Keep the first implementation pass split into three blocks.

### `engine/`

Owns execution and coordination.

TODO:

- define `ScenarioSpec`, `StepRecord`, and `ScenarioResult`
- implement the thin backend adapter interface
- implement scenario runner flow
- implement task-level scheduler
- implement metric aggregation
- wire isolated worker state and snapshots

Output of this block:

- one scenario can run end to end through Solidity contracts
- each run emits structured step records
- each run emits a structured summary

#### File-Level Breakdown

##### `engine/state.py`

TODO:

- define `WorkerState`
- store active `ScenarioSpec`
- store current step index
- track snapshot IDs
- expose current state summaries

Minimum outcome:

- the worker can snapshot and revert isolated execution state
- the runner can query the latest local execution state

##### `engine/adapters/moccasin.py`

TODO:

- define the backend adapter class
- deploy or load contracts
- send actions as transactions
- query pool and position state
- decode receipts and logs
- support snapshot and revert

Minimum outcome:

- one scenario can execute against real Solidity contracts
- the backend stays thin and protocol-agnostic

##### `engine/adapters/foundry.py`

TODO:

- mirror the adapter interface used by Moccasin
- provide a secondary local execution backend
- keep the contract shape stable across backends

Minimum outcome:

- the engine can switch execution backends without changing runner logic

##### `engine/runner.py`

TODO:

- load one `ScenarioSpec`
- initialize actor policies
- build the scenario action sequence
- call the adapter in order
- collect `StepRecord` objects
- hand final steps to the metrics layer

Minimum outcome:

- one scenario can run end to end
- each action becomes one recorded step

##### `engine/scheduler.py`

TODO:

- expand one spec into many repetitions
- distribute instances across workers
- collect results from workers
- capture failures and retries

Minimum outcome:

- multiple scenario instances can run in parallel
- scheduling remains separate from protocol logic

##### `engine/metrics.py`

TODO:

- compute `fee_capture_by_actor`
- compute `realized_pnl`
- compute `inventory_drift`
- compute `boundary_hit_rate`
- compute `cross_count`
- aggregate step records into scenario summaries

Minimum outcome:

- raw traces become structured summaries
- metric definitions stay centralized

##### `engine/__init__.py`

TODO:

- expose the minimal public engine API

Minimum outcome:

- consumers can import the engine without knowing internal file layout

### `strategies/`

Owns participant behavior.

TODO:

- define passive LP policy
- define boundary pinning attacker policy
- define directional trader policy
- define cross-reverse farmer policy
- define deterministic and seeded policy variants

Output of this block:

- the runner can ask policies for actions
- scenario behavior is configurable without changing execution code
- the same scenario can be replayed with different policies

#### File-Level Breakdown

##### `strategies/trader.py`

TODO:

- define a base trader policy interface
- implement directional trader flow
- implement bursty flow
- implement random-walk flow
- support deterministic and seeded variants

Minimum outcome:

- the runner can request the next trader action from a policy object

##### `strategies/lp.py`

TODO:

- define a base LP policy interface
- implement passive wide LP layouts
- implement narrow boundary LP layouts
- implement layered grid LP layouts
- support repeatable layout generation from seed

Minimum outcome:

- the scenario builder can generate LP placements without hardcoding them in runner logic

##### `strategies/attacker.py`

TODO:

- define a base attacker policy interface
- implement boundary pinning attacker behavior
- implement cross-reverse farmer behavior
- implement JIT-style insertion behavior
- support deterministic and seeded attack variants

Minimum outcome:

- the same scenario can be run with different adversarial policies

##### `strategies/__init__.py`

TODO:

- expose the minimal policy interfaces

Minimum outcome:

- consumers can import policy types from one place

### `datasets/`

Owns inputs, outputs, and replay material.

TODO:

- define YAML spec fixtures
- store raw step records in `parquet`
- store scenario summaries in `csv` or `parquet`
- store replay artifacts and failure cases
- keep fixture data versioned with the scenario definitions

Output of this block:

- scenario runs can be reproduced
- outputs can be analyzed in notebooks
- step traces can be replayed after the run

#### File-Level Breakdown

##### `datasets/fixtures/`

TODO:

- store scenario YAML files
- keep fixed pool setups
- keep seedable actor layouts
- version fixtures alongside scenario definitions

Minimum outcome:

- scenarios can be loaded from a stable fixture set

##### `datasets/outputs/`

TODO:

- store raw step traces
- store scenario summaries
- store failure cases
- store replay artifacts

Minimum outcome:

- all run results are persisted in a structured and queryable form

##### `datasets/README.md`

TODO:

- document file formats
- document naming conventions
- document replay expectations

Minimum outcome:

- future users know where inputs and outputs live

##### `datasets/__init__.py`

TODO:

- expose dataset utility helpers if needed

Minimum outcome:

- dataset helpers can be imported without depending on internal paths

### Recommended Order

1. build `engine/`
2. add `strategies/`
3. formalize `datasets/`

That order keeps protocol truth in the backend first and avoids building data
pipelines before there is something real to run.

## Development Checklist

1. Define `ScenarioSpec`, `StepRecord`, and `ScenarioResult`.
2. Lock the YAML schema for `specs/`.
3. Implement `engine/state.py` with snapshot and rollback support.
4. Implement `engine/adapters/moccasin.py` as the first thin backend.
5. Implement `engine/runner.py` for one end-to-end scenario instance.
6. Implement `engine/metrics.py` for the core metric set.
7. Implement `engine/scheduler.py` for local multi-process execution.
8. Add `strategies/trader.py`, `strategies/lp.py`, and `strategies/attacker.py`.
9. Add `datasets/fixtures/` and `datasets/outputs/` conventions.
10. Run the three MVP scenarios and verify reproducible structured outputs.

## Summary

`uniswap-sim` is a research engine for structured experimentation on top of real Uniswap V3 contract execution.

It exists to answer questions like:

- which LP layout captures more fees under a given flow regime?
- how path-dependent are outcomes under repeated crossing?
- how do adversarial strategies change the distribution of returns?
- when does decomposition matter economically?

The guiding idea is simple:

Use Solidity to define truth. Use Python to explore the scenario space.
