# Uniswap V3 Runtime Oracle Manipulation Demo

## Summary

This note records a small **local runtime experiment** on Uniswap V3 oracle behavior.

The goal was not to show a core pool-drain bug, but to construct and inspect a concrete
state where:

- **spot price** is materially displaced
- **short-window TWAP** still reflects the recent prior regime
- a simple runtime checker can flag the resulting manipulation surface

In the demonstrated local scenario:

- `spot tick = -1`
- `twap tick = 54`
- `tick deviation = -55`
- `price deviation = 54.1433 bps`
- checker verdict: **`elevated`** fileciteturn6file0

This is exactly the kind of state that matters for downstream systems that consume:

- spot too naively
- very short TWAPs
- oracle readings without enough historical depth or manipulation resistance

---

## What was built

The local workflow used three components:

1. **Foundry deploy script**
   - deploy a local Uniswap V3 environment
   - write deployment metadata for later inspection

2. **Foundry drive script**
   - move pool state into a chosen local scenario
   - create a runtime state where spot and TWAP diverge

3. **Python runtime checker**
   - connect to Anvil via RPC
   - read pool state directly
   - compare current spot state against a requested TWAP window
   - classify the resulting manipulation surface

The Python checker was extended to support:

- `--rpc-url`
- `--deployment-file`
- `--window`
- `--warn-bps`
- `--fallback-window`

and to report:

- pool metadata
- active liquidity
- `slot0`
- oracle observation state
- TWAP window and effective fallback window
- spot tick / TWAP tick deviation
- spot/TWAP price deviation in bps
- lower/upper boundary tick state when available fileciteturn6file4

---

## Command used

```bash
uv run uni_v3_check.py \
    --rpc-url http://127.0.0.1:8545 \
    --deployment-file cache/local_univ3_deployment.json \
    --window 10 \
    --warn-bps 25 \
    --fallback-window
```

---

## Observed output

```text
Uniswap V3 Runtime Check
pool: 0x8641Bb79917BBe4bc88D709bAd14b6c5Eb26df7A
token0: 0x0B306BF915C4d645ff596e518fAf3F9669b97016
token1: 0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1
fee: 3000
active liquidity: 2000000000000000000
spot sqrtPriceX96: 79228162514264337593543950336
spot tick: -1
observation index/cardinality/cardinalityNext: 3/16/16
requested twap window: 10s
effective twap window: 10s
twap tick: 54
tick deviation: -55
raw spot price token1/token0: 1.000000000000000000000000
raw twap price token1/token0: 1.005414334835656750944885
price deviation: 54.1433 bps
manipulation surface: elevated

lower tick 0:
  initialized: True
  liquidityGross: 2000000000000000000
  liquidityNet: 2000000000000000000

upper tick 60:
  initialized: True
  liquidityGross: 2000000000000000000
  liquidityNet: -2000000000000000000
``` 

---

## Why the checker marked this as `elevated`

The checker classifies the manipulation surface using two signals:

- **price deviation in bps**
- **tick gap**

The relevant classification logic is:

- `critical` if `price_deviation >= warn_bps * 5` or `|tick_gap| >= 250`
- `elevated` if `price_deviation >= warn_bps` or `|tick_gap| >= 100`
- otherwise `normal` unless liquidity is zero fileciteturn6file4

In this run:

- `warn_bps = 25`
- `price deviation = 54.1433 bps`
- `tick deviation = -55`

So:

- `54.1433 >= 25` ⇒ `elevated`
- but `54.1433 < 125` and `|55| < 100` ⇒ not `critical`

This is a useful reminder that interpretation depends on the threshold regime.
The script default is `--warn-bps 100`, but this run intentionally lowered the warning threshold to 25 bps. fileciteturn6file4turn6file0

---

## What this runtime state means

This state is interesting because the pool is sitting in a visibly displaced local regime:

- the current spot is at `tick = -1`
- the short TWAP is still at `tick = 54`
- initialized boundary ticks remain visible at `0` and `60` fileciteturn6file0

That means the runtime state is not just “price moved.”
It is:

**spot has been pulled toward or across the boundary while the short-window oracle still remembers the previous in-range environment.**

This is exactly the kind of local state that can matter for:

- lending protocols using too-short V3 TWAP windows
- vaults that rebalance on fragile local oracle reads
- liquidators that treat short-window TWAP as if it were manipulation-resistant
- any integration that assumes spot and short TWAP remain tightly coupled under local stress

---

## Why this does not imply a Uniswap V3 core bug

This demo does **not** show that Uniswap V3 core accounting is broken.

Instead, it shows something narrower and more realistic:

- the pool can enter a local runtime state where spot and short TWAP diverge materially
- a consumer that samples that state naively may face an oracle manipulation surface
- the relevant risk is often in the **integration**, not in core solvency or fee accounting

This is consistent with a broader review pattern:

- core can be internally coherent
- yet downstream protocols can still be exposed if they read V3 too naively

---

## Why the boundary information matters

The reported boundary state is:

- lower tick `0`: initialized, positive `liquidityNet`
- upper tick `60`: initialized, negative `liquidityNet` fileciteturn6file0

This confirms that the local deployment was operating around a single seeded liquidity band.
That matters because short-window manipulation around one active band is often much more informative than broad “price moved” language.

A boundary-local runtime detector is more useful than a generic spot/TWAP comparison because it helps answer:

- **where** the active liquidity is concentrated
- whether spot is being pinned near one edge
- whether oracle readings are still anchored to the interior of the range

---

## Design notes on the checker

A few parts of the checker are especially useful for local protocol research:

### 1. Fallback window support

The script can fall back to the largest available historical TWAP window if the requested one is unavailable.
This makes it usable on:

- fresh local deployments
- forked pools with incomplete requested history
- scenarios where observation history is still short fileciteturn6file4

### 2. Runtime boundary inspection

The checker can read lower and upper tick state directly and will also use deployment hints when available.
That makes it much easier to connect:

- spot state
- oracle state
- local liquidity topology fileciteturn6file4

### 3. Explicit surface classification

The `normal / elevated / critical` labeling is intentionally simple.
It is not meant to be a formal security proof.
It is meant to help quickly triage local runtime states and decide which scenarios deserve deeper testing. fileciteturn6file4

---

## What this is useful for

This kind of runtime check is useful as a bridge between:

- static protocol reading
- adversarial scenario design
- local or fork-based experimentation

In practice, it can be reused to support:

- oracle manipulation demos
- local boundary stress tests
- pre-integration review of V3-dependent systems
- post-deployment sanity checks on custom CLAMM forks

---

## Next steps

Natural extensions of this experiment include:

1. measure the same setup across multiple TWAP windows
   - e.g. 1s, 5s, 10s, 30s, 60s

2. replay the same checker on forked pools with realistic liquidity topology

3. combine this runtime check with adversarial flow scripts that:
   - pin spot near one edge
   - cross and reverse one hot boundary
   - compare short TWAP consumers against longer-window consumers

4. produce protocol-specific checks for systems that rely on Uniswap V3 as an oracle input

---

## Closing view

A useful way to think about this result is:

**this is not a Uniswap V3 insolvency bug; it is a runtime oracle-consumption warning.**

The important point is not that spot and TWAP can differ.
The important point is:

- how much they differ
- over what window
- around which active boundary
- and whether downstream systems are robust to that local state

That is where concentrated-liquidity integration risk becomes real.
