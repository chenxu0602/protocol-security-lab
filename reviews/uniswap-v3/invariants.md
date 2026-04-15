# Invariants

## 1. Pool identity must remain unique per `(token0, token1, fee)`
### Statement
For any canonical token ordering and enabled fee tier, there must be at most one canonical pool address, and that address must match the CREATE2 deployment path used by the factory/deployer pair.

### Why It Matters
Pool uniqueness is the root assumption behind routing, oracle consumption, and liquidity concentration into a single canonical market per pair/fee.

### Relevant Mechanisms
- `UniswapV3Factory.createPool()`
- `UniswapV3PoolDeployer.deploy()`
- `getPool[token0][token1][fee]`

### What Could Break It
- inconsistent token sorting
- duplicate deployment path
- mismatch between CREATE2 salt derivation and factory mapping updates

---

## 2. `slot0` must always describe a self-consistent current execution state
### Statement
The pool’s current `sqrtPriceX96`, `tick`, oracle indices/cardinality fields, packed protocol-fee configuration, and lock state must remain mutually consistent after every completed state transition.

### Why It Matters
`slot0` is the main execution anchor for swaps, position updates, oracle reads, and governance-fee logic. Drift here breaks nearly every other accounting path.

### Relevant Mechanisms
- `initialize()`
- `swap()`
- `increaseObservationCardinalityNext()`
- `setFeeProtocol()`

### What Could Break It
- partial state updates during swap finalization
- inconsistent tick/price recomputation
- malformed oracle index/cardinality updates
- fee-protocol packing/unpacking mismatch
- lock flag not restored on success paths

---

## 3. Active liquidity must equal current in-range liquidity, not total position liquidity
### Statement
The pool-level `liquidity` variable must represent only liquidity currently active at the current tick, and it must change only when positions are added/removed in-range or when initialized ticks are crossed.

### Why It Matters
Swap pricing, fee growth attribution, and oracle `secondsPerLiquidity` all depend on current active liquidity rather than the sum of all LP positions.

### Relevant Mechanisms
- `_modifyPosition()`
- `_updatePosition()`
- `swap()`
- `Tick.cross()`
- `LiquidityMath.addDelta()`

### What Could Break It
- wrong sign handling for `liquidityNet`
- applying tick-crossing liquidity changes in the wrong direction
- updating pool liquidity when position changes are fully out of range

---

## 4. Tick boundary state must encode range effects correctly
### Statement
For each initialized tick, `liquidityGross` and `liquidityNet` must correctly represent how all positions using that tick as a boundary affect active liquidity when the price crosses that boundary.

### Why It Matters
Uniswap V3 does not update every tick in a range. It encodes a position through its lower and upper boundaries. If those boundary effects are wrong, active liquidity becomes wrong.

### Relevant Mechanisms
- `Tick.update()`
- `Tick.cross()`
- `_updatePosition()`
- `tickBitmap.flipTick()`

### What Could Break It
- lower/upper liquidity sign inversion
- incorrect tick flip conditions
- clearing tick data while still referenced by surviving liquidity

---

## 5. Fee growth inside a range must be reconstructible from global and lower/upper outside state
### Statement
For any initialized `(tickLower, tickUpper)` pair, `feeGrowthInside` must equal the portion of global fee growth attributable to liquidity inside that range, based on current tick location and the lower/upper ticks’ outside accumulators.

### Why It Matters
LP fee entitlement is not tracked continuously per position. It is lazily reconstructed from global and boundary state. Any inside/outside error misallocates fees across LPs. Previously accrued fee entitlement for positions that later move out of range must remain recoverable through this reconstruction path.

### Relevant Mechanisms
- `Tick.getFeeGrowthInside()`
- `_updatePosition()`
- `Position.update()`
- `swap()`

### What Could Break It
- incorrect interpretation of lower vs upper boundary relative to `currentTick`
- stale or wrongly flipped `feeGrowthOutside`
- wrong token-side fee growth selected during swaps

---

## 6. A position’s `tokensOwed` must only reflect crystallized entitlement
### Statement
`positions[key].tokensOwed0/1` should increase only when fee growth or burn proceeds are crystallized into that position, and `collect()` must not pay more than the already-recorded owed amount.

### Why It Matters
This is the core separation between lazy fee accounting and actual withdrawal rights. If `tokensOwed` can drift or be over-withdrawn, LP value can be stolen or double-counted.

### Relevant Mechanisms
- `Position.update()`
- `_modifyPosition()`
- `burn()`
- `collect()`

### What Could Break It
- updating checkpoints in the wrong order
- double-crediting burn proceeds and fee growth
- `collect()` bypassing the recorded owed cap

---

## 7. Swap fees must be attributed only to liquidity active during that step
### Statement
Within each swap step, fee growth added to `feeGrowthGlobal{0,1}X128` must correspond only to the liquidity active during that step, before any later tick crossing changes active liquidity.

### Why It Matters
If fees are attributed using the wrong liquidity base or after crossing effects, LPs in adjacent ranges can subsidize or steal fees from each other.

### Relevant Mechanisms
- `SwapMath.computeSwapStep()`
- `swap()`
- `ticks.cross()`
- `state.liquidity`
- `state.feeGrowthGlobalX128`

### What Could Break It
- applying liquidity updates before step fee attribution
- using the wrong token-side global fee tracker
- rounding or sign mistakes in exact-input / exact-output paths

---

## 8. Protocol fees must remain disjoint from LP fee growth
### Statement
The protocol fee portion taken from swap or flash fees must be carved out before LP fee growth is credited, and protocol-fee withdrawals must not reduce LP fee entitlement.

### Why It Matters
LP fees and protocol fees share the same economic source but must remain separate accounting domains.

### Relevant Mechanisms
- `swap()`
- `flash()`
- `setFeeProtocol()`
- `collectProtocol()`
- `protocolFees`

### What Could Break It
- protocol skim applied after LP fee growth update
- wrong token-side denominator unpacking
- protocol withdrawal touching LP-owned balances or fee growth

---

## 9. Callback-based settlement must leave the pool fully paid
### Statement
After `mint`, `swap`, and `flash` callbacks return, the pool’s token balances must satisfy the required minimum post-callback repayment condition for the owed token side(s).

### Why It Matters
The pool intentionally sends or accounts for value before external callback settlement. Balance-before / balance-after enforcement is the core defense against underpayment.

### Relevant Mechanisms
- `mint()`
- `swap()`
- `flash()`
- `balance0()`
- `balance1()`

### What Could Break It
- incorrect balance snapshot token side
- underflow/overflow in required repayment amount
- callback path that can satisfy checks while underpaying economically

---

## 10. Tick crossing must flip outside accumulators without losing total cumulative meaning
### Statement
When an initialized tick is crossed, its `feeGrowthOutside`, `tickCumulativeOutside`, `secondsPerLiquidityOutsideX128`, and `secondsOutside` must flip to the opposite side of the boundary while preserving correct global-minus-outside interpretation.

### Why It Matters
Crossing is the bridge between swap progression and boundary accounting. If outside accumulators are not flipped correctly, both fee settlement and inside-range historical reconstruction break.

### Relevant Mechanisms
- `Tick.cross()`
- `swap()`
- `snapshotCumulativesInside()`
- `Tick.getFeeGrowthInside()`

### What Could Break It
- crossing with wrong token-side fee globals
- missing observation-derived cumulative values before first initialized crossing
- direction-dependent sign mistakes

---

## 11. Oracle observations must remain ordered and support correct cumulative differencing
### Statement
Observation writes and reads must preserve chronological ordering and cumulative semantics so that differencing two snapshots yields correct average tick and liquidity-time information.

### Why It Matters
The oracle stores cumulative history rather than spot prices. Any corruption in write order, interpolation, or cardinality management breaks TWAP-style consumers.

### Relevant Mechanisms
- `Oracle.write()`
- `Oracle.observe()`
- `observe()`
- `increaseObservationCardinalityNext()`
- `snapshotCumulativesInside()`

### What Could Break It
- cardinality/index mismanagement
- missing write on tick-changing swap path
- bad interpolation around newest/oldest observation boundaries

---

## 12. Range-inside cumulative reconstruction must match current tick location
### Statement
`snapshotCumulativesInside(tickLower, tickUpper)` should reconstruct inside cumulative values consistently for all three cases: current tick below range, inside range, and above range.

### Why It Matters
Uniswap V3 uses lower/upper boundary outside values plus current/global state to derive inside values. This is a core primitive for range analytics and historical reasoning.

### Relevant Mechanisms
- `snapshotCumulativesInside()`
- `Tick.Info.tickCumulativeOutside`
- `Tick.Info.secondsPerLiquidityOutsideX128`
- `Tick.Info.secondsOutside`

### What Could Break It
- lower/upper branch inversion
- failing to require initialized boundary ticks
- inconsistency between current tick and current cumulative observation

---

## 13. Exact-input and exact-output swaps must preserve the intended amount semantics
### Statement
In exact-input mode, the user’s remaining specified amount should decrease by input plus fee, while output is derived; in exact-output mode, remaining specified amount should shrink by output delivered while input owed is derived, without sign inversion, token-side inversion, or fee-side misclassification.

### Why It Matters
The swap loop handles both modes in the same machinery. Sign or token-direction mistakes can invert repayment obligations or produce too much output.

### Relevant Mechanisms
- `swap()`
- `SwapMath.computeSwapStep()`
- `amountSpecifiedRemaining`
- `amountCalculated`

### What Could Break It
- exact-input / exact-output branch inversion
- wrong mapping of `amount0` / `amount1` under `zeroForOne`
- incorrect treatment of fee as input-side amount

---

## 14. Price movement must never overshoot the chosen target boundary or user limit
### Statement
Each swap step must move the current sqrt price only up to the nearer of the next initialized-tick price and the caller-specified sqrt price limit, without overshooting either boundary.

### Why It Matters
This is the core local safety property of swap execution. Overshoot breaks expected slippage bounds and the correctness of tick-crossing transitions.

### Relevant Mechanisms
- `SwapMath.computeSwapStep()`
- `swap()`
- `TickMath.getSqrtRatioAtTick()`
- `sqrtPriceLimitX96`

### What Could Break It
- wrong target-price selection under `zeroForOne`
- rounding that steps beyond the intended boundary
- mismatch between next-tick price and recomputed current tick

---

## 15. Reentrancy and execution-context assumptions must hold on sensitive paths
### Statement
State-changing pool actions must not be reentered in a way that violates sequencing assumptions, and functions guarded by `noDelegateCall` must execute only in their native storage context.

### Why It Matters
The design intentionally combines external callbacks with balance checks and internal sequencing. Those assumptions fail if reentrancy or delegatecall changes the execution model.

### Relevant Mechanisms
- `lock`
- `noDelegateCall`
- `mint()`
- `swap()`
- `flash()`
- `collect()`
- `collectProtocol()`

### What Could Break It
- missing lock coverage on callback-sensitive state transitions
- delegatecall into protected execution paths
- partial state update before external interaction

---

## 16. Flash fee accrual must be based on actual paid amounts
### Statement
Fee growth and protocol fee extraction during `flash()` must be based on the actual paid token amounts above pre-flash balances, not merely on nominal quoted fees.

### Why It Matters
Flash callbacks may repay more than the minimum required amount. LP and protocol accounting must follow actual value returned to the pool.

### Relevant Mechanisms
- `flash()`
- `paid0`
- `paid1`
- `feeGrowthGlobal0X128`
- `feeGrowthGlobal1X128`
- `protocolFees`

### What Could Break It
- fee accrual based only on quoted `fee0/fee1`
- incorrect separation between minimum repayment validation and actual-fee accounting
- token-side mismatch in protocol fee extraction

---

## 17. Position inventory decomposition must match current price regime
### Statement
For any position update, token deltas implied by liquidity changes must match the current price regime: below-range positions should decompose to token0 only, above-range positions to token1 only, and in-range positions to both token0 and token1 according to current sqrt price and range boundaries.

### Why It Matters
This is the core concentrated-liquidity inventory invariant. If decomposition is wrong, mint/burn accounting and position value transfer become incorrect.

### Relevant Mechanisms
- `_modifyPosition()`
- `SqrtPriceMath.getAmount0Delta()`
- `SqrtPriceMath.getAmount1Delta()`
- `TickMath.getSqrtRatioAtTick()`

### What Could Break It
- inverted lower/upper usage
- wrong current-price-relative delta intervals
- incorrect sign handling for negative liquidity deltas