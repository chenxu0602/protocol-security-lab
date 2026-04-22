# uniswap-sim

`uniswap-sim` is a Python-driven research simulation engine for Uniswap V3.
It uses Solidity contracts as the source of truth and focuses on batch scenario
execution, structured metrics, and replayable analysis.

It is not a replacement for Foundry.

Foundry stays responsible for protocol semantics, unit tests, invariant tests,
regression coverage, and boundary correctness.

This project exists to answer questions that single-path tests do not:

- How do fee capture and PnL distribute across many scenario realizations?
- How sensitive are outcomes to path dependence and boundary oscillation?
- Which liquidity layouts perform better under repeated adversarial flow?
- When does decomposition change the economic outcome?

The design rule is simple:

**Solidity defines truth. Python explores the scenario space.**

## Core Concepts

- `spec`: defines what to run.
- `runner`: translates a scenario into onchain actions.
- `worker`: executes one isolated scenario instance.
- `metrics`: transforms traces into structured outputs.
- `store`: persists raw and summarized results.

## MVP Scope

Start with three scenario families:

- `boundary_pinning`
- `cross_reverse_farming`
- `position_decomposition`

These map directly onto the existing Foundry harness and are good targets for
distributional analysis.

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

- `specs/` describes what should be simulated.
- `engine/runner.py` defines action order.
- `engine/scheduler.py` distributes work across workers.
- `engine/metrics.py` computes outputs.
- `strategies/` defines participant behavior.
- `datasets/` stores raw traces, summaries, and replay data.
- `reports/` holds notebooks, charts, and written summaries.

## Execution Model

Each scenario instance should run in its own isolated worker process. The
worker should execute the scenario through a thin EVM adapter, record step
results, and emit structured summaries.

## Metrics

The engine should produce both step-level records and scenario-level results.
Core outputs include fee capture, realized PnL, inventory drift, gas used,
boundary hit rate, and cross count.

## Backends

Moccasin is the first backend, but the engine should stay backend-agnostic.
The adapter layer should only deploy contracts, send transactions, query
state, decode receipts, and manage snapshots.

## Relationship to Foundry

Foundry proves semantic correctness.
Python measures scenario behavior.

That boundary should stay strict.

