# Uniswap V3 Review Note

This week I reviewed the core accounting and execution paths of **Uniswap V3 core**, with the main goal of understanding whether the protocol’s highest-friction concentrated-liquidity mechanics show obvious local inconsistencies under targeted testing.

## Scope

This review focused on **v3-core**, not the periphery wrapper stack.

Main files reviewed:
- `UniswapV3Pool.sol`
- `Tick.sol`
- `Position.sol`
- `Oracle.sol`
- `SwapMath.sol`
- `SqrtPriceMath.sol`
- `TickMath.sol`
- `UniswapV3Factory.sol`
- `UniswapV3PoolDeployer.sol`

## Main Review Themes

The review concentrated on the following correctness surfaces:

1. **Initialized-tick crossing and active-liquidity transitions**
   - whether `liquidityNet` is applied with the correct sign
   - whether leftward and rightward crossings restore the correct active-liquidity set
   - whether exact-hit boundary paths behave consistently

2. **Fee-growth reconstruction and lazy fee crystallization**
   - whether `feeGrowthInside` is reconstructible from global and lower/upper outside accumulators
   - whether previously earned fee entitlement remains recoverable after positions move below range or above range
   - whether `burn(0)` behaves sensibly as a crystallization path

3. **Per-step fee attribution**
   - whether fees are attributed only to liquidity active during the relevant swap step
   - whether fee attribution stays coherent when a step ends exactly on, or crosses, an initialized tick
   - whether crossing changes affect only subsequent steps

4. **Position inventory decomposition**
   - whether liquidity changes decompose into the correct token0/token1 mix
   - whether below-range, in-range, and above-range inventory regimes match expected V3 geometry
   - whether exact-boundary transitions preserve the expected conventions

## Review Artifacts

The review produced:
- `threat-model.md`
- `function-notes.md`
- `invariants.md`
- `issue-candidates.md`

and a local Foundry harness covering:
- `PoolCrossingDirection.t.sol`
- `FeeGrowthInsideBoundary.t.sol`
- `StepFeeAttribution.t.sol`
- `PositionDecomposition.t.sol`

with additional bounded fuzz coverage for:
- regime-consistent mint / burn decomposition
- crossing net-liquidity changes and round-trip survivability

## What the Current Evidence Suggests

The current review **does not support a simple claim that Uniswap V3 core accounting is broken in the reviewed paths**.

The strongest local evidence gathered so far supports the following:

- initialized-tick crossing directionality looks coherent in the reviewed paths
- active liquidity appears to update by the expected net amount at crossings
- per-step fee attribution appears to stay with the liquidity active during that step
- previously earned fee entitlement appears recoverable across below-range / in-range / above-range transitions
- mint / burn token decomposition appears consistent with the current price regime, including reviewed exact-boundary paths

In other words, several classic concentrated-liquidity bug hypotheses were **meaningfully weakened by direct targeted tests**, even though they remain important review surfaces in principle.

## Important Semantic Notes

A few behaviors are important to understand as **protocol semantics**, not immediate bugs:

- `collect()` only withdraws already-crystallized `tokensOwed`; it does **not** itself force newly accrued fees to crystallize
- increasing observation cardinality is **not** the same as immediately creating deeper usable oracle history
- flash accounting is based on **actual paid amounts**, not merely nominal quoted minimum fees
- exact boundary semantics depend on the distinction between current `tick` and current `sqrtPriceX96`

## What Remains Most Worth Testing

The highest-value remaining review surfaces are:

- oracle observation ordering, interpolation, and cumulative reconstruction stress paths
- direct protocol-fee directional attribution tests
- broader multi-tick adversarial paths
- more aggressive fuzz coverage around exact-boundary transitions
- integration assumptions around non-standard ERC20 behavior

## Overall Takeaway

At this stage, the Uniswap V3 core review looks **less like a protocol with an already-reproduced core accounting break**, and more like a protocol where the most feared concentrated-liquidity failure modes need to be tested carefully — and where several of those fears become less convincing after direct local validation.

That is a good review outcome.

It does **not** mean review is complete. It means the next work should stay focused on the remaining high-leverage surfaces rather than re-proving the same crossing and decomposition mechanics again.