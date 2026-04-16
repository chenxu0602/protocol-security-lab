# Uniswap V3 Adversarial Check

- Summary: `2 pass`, `0 fail`, `6 warn`

## [PASS] `attack-callback-reentrancy` Callback Reentrancy Escape

Models the canonical V3 exploit attempt: use the callback as an attacker-controlled execution window to re-enter stateful paths before payment checks or storage finalization.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:104: modifier lock() {`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:105: require(slot0.unlocked, 'LOK');`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:106: slot0.unlocked = false;`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:615: slot0.unlocked = false;`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:108: slot0.unlocked = true;`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:787: slot0.unlocked = true;`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:482: IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:776: IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:782: IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:808: IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:777: require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:783: require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');`

Notes:
- Attack model: recurse from mint/swap/flash callbacks to re-enter settlement paths before balances are checked.
- Mitigation present: pool-wide lock gates mint/burn/collect/flash and swap manually acquires the same lock before the external callback.
- Residual risk: integrations that compose multiple pools or trust callback caller identity still need their own callback auth checks.

## [WARN] `attack-same-block-oracle` Same-Block Oracle Manipulation

Models adversarial price movement against downstream protocols rather than direct theft from the pool. The script looks for the exact V3 oracle semantics that determine how much same-block manipulation room integrators still have.

Evidence:
- `lib/uniswap-v3-core/contracts/libraries/Oracle.sol:90: if (last.blockTimestamp == blockTimestamp) return (index, cardinality);`
- `lib/uniswap-v3-core/contracts/libraries/Oracle.sol:254: if (secondsAgo == 0) {`
- `lib/uniswap-v3-core/contracts/libraries/Oracle.sol:256: if (last.blockTimestamp != time) last = transform(last, time, tick, liquidity);`
- `lib/uniswap-v3-core/contracts/libraries/Oracle.sol:226: require(lte(time, beforeOrAt.blockTimestamp, target), 'OLD');`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:341: (slot0.observationIndex, slot0.observationCardinality) = observations.write(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:735: observations.write(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:341: (slot0.observationIndex, slot0.observationCardinality) = observations.write(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:211: observations.observeSingle(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:397: observations.observeSingle(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:699: (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(`

Notes:
- Attack model: move price, force an in-block observation context, and have an external integrator read spot or very short TWAP in the same block.
- Finding: V3 prevents duplicate oracle writes in one block, but that is not a complete defense against oracle manipulation for consumers that sample too short a window.
- Operational implication: this is not a pool-drain bug in core; it is an integration attack surface for lending, vault, and liquidation systems that read from V3 too naively.

## [WARN] `attack-jit-liquidity` Just-In-Time Liquidity Fee Sniping

Models an MEV-style attack on LP economics. This is the class of issue routine static analyzers miss because the exploit lives in timing and fee-accounting semantics, not low-level safety bugs.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:457: function mint(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:517: function burn(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:490: function collect(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:442: position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:537: position.tokensOwed0 + uint128(amount0),`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:538: position.tokensOwed1 + uint128(amount1)`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:440: ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);`

Notes:
- Attack model: backrun a large swap with narrowly placed liquidity, earn fees for one block or one transaction range, then burn and collect immediately.
- Finding: core intentionally allows this. It is an economic extraction vector, not a correctness bug, and it matters whenever a fork or integration assumes 'passive LP' economics.
- What to test on forks: compare fee capture for just-in-time LP against long-lived LP under extreme tick concentration and verify whether protocol wrappers accidentally amplify it.

## [WARN] `attack-donation-desync` Donation / Balance Desynchronization

Models attacks that do not violate the pool’s own invariants but can poison external accounting by changing balances outside expected entrypoints.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:140: function balance0() private view returns (uint256) {`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:150: function balance1() private view returns (uint256) {`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:483: if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:484: if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:777: require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:783: require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:813: require(balance0Before.add(fee0) <= balance0After, 'F0');`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:814: require(balance1Before.add(fee1) <= balance1After, 'F1');`

Notes:
- Attack model: donate tokens directly to the pool or use weird transfer semantics so callback settlement succeeds against a distorted balance baseline.
- Finding: V3 uses `>=` balance-delta assertions rather than exact settlement. That is intentional and safe for core solvency, but donations and rebases can create accounting surprises for wrappers that infer provenance from raw balances.
- What to test on forks: unsolicited token donations before swap/mint, rebasing tokens, fee-on-transfer tokens, and any adapter that assumes pool balances only change through pool code paths.

## [WARN] `attack-observation-griefing` Observation Cardinality Griefing

Models a non-theft attacker whose goal is to increase gas costs or operational burden rather than steal assets immediately.

Evidence:
- `lib/uniswap-v3-core/contracts/libraries/Oracle.sol:108: function grow(`
- `lib/uniswap-v3-core/contracts/libraries/Oracle.sol:118: for (uint16 i = current; i < next; i++) self[i].blockTimestamp = 1;`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:255: function increaseObservationCardinalityNext(uint16 observationCardinalityNext)`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:263: observations.grow(observationCardinalityNextOld, observationCardinalityNext);`

Notes:
- Attack model: grief the pool by increasing observation cardinality so future swaps inherit a larger storage footprint and oracle maintenance burden.
- Finding: anyone can pre-pay this storage expansion. It is mostly a gas grief / cost-shifting surface, not a direct fund-loss bug.
- What to test on forks: cardinality jumps before high-volume periods, whether governance wrappers reimburse or subsidize this path, and whether routers misprice gas under max cardinality.

## [WARN] `attack-tick-density-griefing` Dense Tick Gas Griefing

Models adversarial liquidity placement as a gas weapon rather than a pricing edge.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:641: while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:646: (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:710: ticks.cross(`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:128: require(liquidityGrossAfter <= maxLiquidity, 'LO');`
- `lib/uniswap-v3-core/contracts/libraries/TickBitmap.sol:42: function nextInitializedTickWithinOneWord(`
- `lib/uniswap-v3-core/contracts/libraries/TickBitmap.sol:49: if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity`

Notes:
- Attack model: initialize many strategically placed ticks to maximize crossings and push victim swaps toward gas exhaustion or router slippage failure.
- Finding: V3 bounds per-tick liquidity but intentionally permits dense initialized-tick landscapes. This is an execution-cost attack surface, especially for exact-output or tight-slippage routes.
- What to test on forks: adversarial tick initialization around hot price bands and whether your routing or liquidation logic can be griefed into revert or unexpectedly high gas.

## [WARN] `attack-nonstandard-erc20` Non-Standard ERC20 Attack Surface

Models token-behavior attacks where the adversary chooses the asset semantics rather than only the call sequence.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:142: token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:152: token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:505: TransferHelper.safeTransfer(token0, recipient, amount0);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:805: if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:859: TransferHelper.safeTransfer(token0, recipient, amount0);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:509: TransferHelper.safeTransfer(token1, recipient, amount1);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:806: if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:864: TransferHelper.safeTransfer(token1, recipient, amount1);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:143: require(success && data.length >= 32);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:153: require(success && data.length >= 32);`

Notes:
- Attack model: pair the pool against fee-on-transfer, rebasing, callback-heavy, or otherwise non-standard ERC20s and look for settlement/accounting mismatches.
- Finding: core assumes relatively well-behaved ERC20 balance semantics. It defends itself with balance-delta checks, but many exotic tokens remain unsafe or unsupported from an integration perspective.
- What to test on forks: fee-on-transfer under mint and swap, rebases between callback and settlement, and tokens whose `balanceOf` or `transfer` semantics diverge from vanilla ERC20 expectations.

## [PASS] `attack-fee-wraparound` Accumulator Wraparound Attack Surface

Models adversarial pressure on fee accumulators and distinguishes deliberate wraparound-safe arithmetic from genuinely unsafe overflow.

Evidence:
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:78: feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:79: feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:93: feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;`
- `lib/uniswap-v3-core/contracts/libraries/Position.sol:64: feeGrowthInside0X128 - _self.feeGrowthInside0LastX128,`
- `lib/uniswap-v3-core/contracts/libraries/Position.sol:72: feeGrowthInside1X128 - _self.feeGrowthInside1LastX128,`
- `lib/uniswap-v3-core/contracts/libraries/Position.sol:83: // overflow is acceptable, have to withdraw before you hit type(uint128).max fees`

Notes:
- Attack model: drive fee accumulators toward wraparound and then realize fees across a boundary where naive analyzers expect underflow or broken accounting.
- Finding: V3 intentionally relies on Solidity 0.7.x modulo arithmetic here. This is subtle enough that many tools either false-positive or fail to explain the real constraint: LPs and protocol fees must be withdrawn before bounded uint128 fee buckets saturate.
# Uniswap V3 Boundary Fee Attack Workbench

- `HIGH-SIGNAL`: 6
- `MEDIUM-SIGNAL`: 2

## [HIGH-SIGNAL] `boundary-pinning` Boundary Pinning Fee Capture

- Attacker goal: Capture a disproportionate share of fees with very little capital by keeping flow oscillating at one hot boundary.
- Mechanism: The attacker provides ultra-narrow liquidity exactly around the current boundary and encourages repeated small swaps that keep price touching but not deeply traversing the band.
- Why V3 is exposed: Fee accrual is driven by active in-range liquidity at the executed path, not by time-weighted TVL. A one- or two-tick band can dominate fee share if most volume clears exactly there.

Trigger conditions:
- Current price is within one tick of a frequently traded boundary.
- Victim LPs are materially wider than the attacker band.
- Order flow is choppy or mean-reverting rather than trend-persistent.

Leverage points:
- Inside-fee accounting only rewards active range liquidity.
- Boundary-adjacent swaps can route volume through a narrow band many times before wider liquidity meaningfully participates.
- Ending one tick above versus below the boundary changes which range is active.

Signals to measure:
- Attacker fee share / attacker active liquidity.
- Victim fee share dilution versus pro-rata TVL baseline.
- Fraction of volume executed while price remained within one spacing of the target boundary.

Test outline:
- Mint a wide passive victim range and a 1-2 tick attacker range around spot.
- Run alternating small swaps that keep price bouncing across the same boundary.
- Burn and collect for both parties, then compare fee-per-liquidity efficiency.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:440: ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:442: position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:331: amount0 = SqrtPriceMath.getAmount0Delta(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:350: amount0 = SqrtPriceMath.getAmount0Delta(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:355: amount1 = SqrtPriceMath.getAmount1Delta(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:365: amount1 = SqrtPriceMath.getAmount1Delta(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:725: state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;`

Notes:
- This is often more profitable than naive JIT because the attacker is exploiting boundary dwell, not only swap size.
- The key measurement is not absolute fees, but fee density at one touched boundary.

## [HIGH-SIGNAL] `cross-reverse-farming` Cross-and-Reverse Tick Farming

- Attacker goal: Farm fees by repeatedly forcing the same initialized tick to be crossed and uncrossed while owning the tight liquidity on both sides.
- Mechanism: The attacker straddles a hot boundary with adjacent narrow positions, then self-trades or backruns natural flow so swaps cross the same tick in both directions.
- Why V3 is exposed: Crossing a tick changes active liquidity and fee-growth-inside attribution. If the attacker controls both sides of the crossing region, oscillation can route a large fraction of fee-paying flow through attacker-owned narrow bands.

Trigger conditions:
- At least one initialized boundary is frequently traversed back and forth.
- Attacker can cheaply place liquidity on both sides of current tick.
- There is enough short-horizon volatility to reverse the crossing without large inventory loss.

Leverage points:
- Per-crossing liquidity sign inversion.
- Tick transition logic decides which band is active after the boundary is hit.
- Repeated recrossing amplifies fee density on local narrow ranges.

Signals to measure:
- Number of attacker-owned crossings per block or per bundle.
- Net inventory drift after two-way crossing cycle.
- Fees earned versus inventory loss over one oscillation cycle.

Test outline:
- Mint two narrow attacker positions on each side of the active tick and one wider victim range.
- Execute a swap that crosses the boundary, then a reverse swap that crosses back.
- Repeat for N cycles and compare attacker fee capture and inventory exposure.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:641: while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:646: (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:710: ticks.cross(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:720: if (zeroForOne) liquidityNet = -liquidityNet;`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:168: function cross(`

Notes:
- This is the fee analogue of volatility harvesting around one boundary.
- The profit condition is high local fee density with bounded inventory drift.

## [HIGH-SIGNAL] `terminal-tick-jit` Terminal-Tick JIT Insertion

- Attacker goal: Insert liquidity only when a pending swap is expected to terminate inside or just adjacent to the attacker band, maximizing fees while reducing adverse selection.
- Mechanism: The attacker conditions JIT liquidity on the expected terminal tick, not merely on swap size. They avoid cases where the victim swap fully blows through the band.
- Why V3 is exposed: The terminal tick determines how much of the narrow band was truly active and how much inventory the attacker ends up holding. V3 fee realization is extremely sensitive to this endpoint.

Trigger conditions:
- Attacker can estimate terminal tick from pending flow size and local liquidity topology.
- Pending swap is large enough to pay meaningful fees but not so large that it fully exhausts the attack band.
- The band can be minted and burned fast enough around one transaction.

Leverage points:
- Price limit and next-tick stepping determine exact path through the band.
- Mint-burn-collect allows single-transaction fee harvesting.
- Profitability changes sharply when terminal tick ends just inside versus just beyond the band.

Signals to measure:
- Profit conditioned on terminal tick ending at -1, 0, +1, +2 ticks relative to attack range edge.
- Inventory imbalance after burn.
- Fee capture ratio versus naive always-on JIT.

Test outline:
- Simulate pending swaps with identical notional but different surrounding liquidity cliffs.
- Mint attacker liquidity only when expected terminal tick lands inside the band.
- Burn, collect, and compare against unconditional JIT.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:457: function mint(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:517: function burn(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:490: function collect(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:600: uint160 sqrtPriceLimitX96,`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:610: ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:610: ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:611: : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:611: : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:641: while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:665: (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)`

Notes:
- This is the mempool-aware version of JIT and is materially sharper than just sandwiching on size.
- The most useful output is a terminal-tick profitability curve.

## [HIGH-SIGNAL] `liquidity-cliff` Liquidity Cliff Fee Extraction

- Attacker goal: Harvest fees in the dense region just before a sharp drop in active liquidity, then let the victim suffer slippage or path deterioration after the crossing.
- Mechanism: The attacker creates a deep fee-paying band up to a boundary and a sparse region immediately after it. Victim flow pays fees in attacker territory before hitting the cliff.
- Why V3 is exposed: Execution is local and stepwise. Routers and users often reason about aggregate depth, while fee extraction depends on the exact local density before the cliff.

Trigger conditions:
- A steep active-liquidity drop exists one initialized tick away from current price.
- Victim flow is large enough to approach but not always fully traverse the cliff.
- Attacker can backrun or hedge after cliff traversal.

Leverage points:
- Per-step fee growth uses current in-range liquidity before each crossing.
- The next initialized tick search makes local topology matter more than global TVL.
- Cliff-shaped liquidity creates high fee density immediately before deterioration.

Signals to measure:
- Fees earned before first cliff crossing.
- Victim execution degradation once sparse region is entered.
- Attacker PnL with and without post-cliff hedge/reversion.

Test outline:
- Construct a deep attacker band from current tick to a nearby boundary and much thinner liquidity after it.
- Run exact-input and exact-output victim swaps through the cliff.
- Measure attacker fees, victim slippage, and attacker backrun profitability.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:646: (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:660: step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:663: (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:690: state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);`
- `lib/uniswap-v3-core/contracts/libraries/TickBitmap.sol:42: function nextInitializedTickWithinOneWord(`

Notes:
- This is often invisible to static analyzers because it depends on liquidity topology, not isolated control flow.

## [HIGH-SIGNAL] `victim-range-starvation` Victim Range Starvation

- Attacker goal: Keep a victim range economically near spot but technically outside the active fee-paying region while the attacker’s tighter range remains active.
- Mechanism: The attacker nudges price to sit barely outside the victim’s lower or upper tick and routes flow while their own tighter range still earns fees.
- Why V3 is exposed: Fee growth inside depends on whether current tick is below, inside, or above each range. A one-tick difference can fully change fee entitlement.

Trigger conditions:
- Victim range edge is close to current price.
- Attacker can maintain price one side of the victim boundary.
- Meaningful flow occurs while victim is just out of range.

Leverage points:
- Fee growth below/above logic in Tick.getFeeGrowthInside.
- Boundary-side classification is discrete rather than continuous.
- Narrow attacker range can stay active while victim wide range is barely inactive.

Signals to measure:
- Victim fee accrual while current tick remains one side of boundary.
- Attacker fee accrual under same path.
- Sensitivity to ending exactly at boundary versus one tick away.

Test outline:
- Set victim range so spot sits near victimTickUpper or victimTickLower.
- Mint an attacker range fully inside the still-active region.
- Drive flow while keeping current tick just outside the victim range and compare fees.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:440: ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:74: if (tickCurrent >= tickLower) {`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:85: if (tickCurrent < tickUpper) {`
- `lib/uniswap-v3-core/contracts/libraries/Position.sol:80: self.feeGrowthInside0LastX128 = feeGrowthInside0X128;`
- `lib/uniswap-v3-core/contracts/libraries/Position.sol:81: self.feeGrowthInside1LastX128 = feeGrowthInside1X128;`

Notes:
- This is particularly relevant for LP vaults that rebalance slowly around price edges.

## [HIGH-SIGNAL] `fee-growth-boundary-gaming` Fee Growth Inside/Outside Boundary Gaming

- Attacker goal: Exploit the discrete inside/outside fee decomposition by controlling which side of lower and upper ticks price spends time on.
- Mechanism: The attacker keeps swaps concentrated around a target position’s boundaries so fee growth is realized in regions that benefit attacker positions and exclude nearby victim positions.
- Why V3 is exposed: Inside-fee calculation is derived from global growth minus below/above components. Boundary side changes are abrupt and path dependent.

Trigger conditions:
- Victim and attacker ranges overlap but have different edges.
- Price can be parked or toggled around one victim boundary.
- Fee-paying flow is local to that boundary window.

Leverage points:
- Discrete branch on `tickCurrent >= tickLower` and `tickCurrent < tickUpper`.
- Outside accumulators are only meaningful relative to current side.
- Two positions with similar economic exposure can realize very different fees.

Signals to measure:
- Fee-growth-inside delta for victim versus attacker over the same swaps.
- Branch sensitivity at boundary tick.
- How much fee share changes when swaps end one tick on either side.

Test outline:
- Deploy partially overlapping attacker and victim ranges with slightly different edges.
- Replay identical swaps under two scenarios: terminal tick just below and just above the boundary.
- Compare realized feeGrowthInside deltas and collected fees.

Evidence:
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:75: feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:78: feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:86: feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:89: feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;`
- `lib/uniswap-v3-core/contracts/libraries/Tick.sol:93: feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;`

Notes:
- This is the most direct place to reason about fee manipulation through boundary placement alone.

## [MEDIUM-SIGNAL] `single-sided-realization` Single-Sided Burn/Collect Timing

- Attacker goal: Choose the exact boundary moment to crystallize fees into tokensOwed while minimizing undesirable inventory composition.
- Mechanism: The attacker waits until price is near a range edge, accumulates fees while the position becomes mostly one-sided, then burns only at the most favorable boundary state.
- Why V3 is exposed: Fee realization and inventory realization happen together on burn. Timing around a boundary can materially change both collected fees and the token mix withdrawn.

Trigger conditions:
- Position has accumulated fees and is near becoming fully one-sided.
- Boundary crossing is expected soon or can be induced.
- Attacker can choose when to burn and collect relative to the crossing.

Leverage points:
- Burn realizes amounts and credits tokensOwed.
- Near-edge positions have highly asymmetric inventory exposure.
- Timing can separate fee capture from adverse inventory more effectively than passive LP behavior.

Signals to measure:
- Collected fees before and after crossing.
- Token composition at burn time.
- Fee-to-inventory-risk ratio across burn timestamps.

Test outline:
- Accumulate fees with a narrow attacker position near one edge.
- Burn in multiple scenarios: just before crossing, exactly after crossing, and several ticks after crossing.
- Compare tokensOwed and ending inventory composition.

Evidence:
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:517: function burn(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:536: (position.tokensOwed0, position.tokensOwed1) = (`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:490: function collect(`
- `lib/uniswap-v3-core/contracts/libraries/Position.sol:79: if (liquidityDelta != 0) self.liquidity = liquidityNext;`
- `lib/uniswap-v3-core/contracts/libraries/Position.sol:82: if (tokensOwed0 > 0 || tokensOwed1 > 0) {`

Notes:
- This is less dramatic than boundary pinning but useful for realistic LP extraction strategies.

## [MEDIUM-SIGNAL] `bitmap-ladder-harvest` Bitmap Ladder Micro-Region Harvest

- Attacker goal: Use a ladder of many nearby narrow ranges to create micro-regions that turn on and off fee entitlement with tiny price moves.
- Mechanism: The attacker initializes a sequence of tightly spaced ranges near spot, so short oscillations repeatedly enter attacker-owned micro-bands.
- Why V3 is exposed: Initialized ticks define where liquidity activates. A dense attacker-controlled ladder gives fine-grained control over where fee-paying liquidity appears.

Trigger conditions:
- Tick spacing is fine enough to build a local ladder near spot.
- Flow is mean-reverting or fragmented into small swaps.
- Attacker can afford the gas and management overhead of many narrow positions.

Leverage points:
- Bitmap controls which initialized ticks are discovered next.
- Local density of initialized bands affects execution path.
- Tiny moves can repeatedly activate attacker micro-regions.

Signals to measure:
- Fee capture from ladder versus one contiguous wide range.
- Gas cost of maintaining the ladder.
- Boundary touch count within the ladder window.

Test outline:
- Mint a ladder of adjacent narrow positions around current price.
- Replay noisy mean-reverting order flow.
- Compare ladder fee capture, gas cost, and victim dilution against a simpler LP baseline.

Evidence:
- `lib/uniswap-v3-core/contracts/libraries/TickBitmap.sol:23: function flipTick(`
- `lib/uniswap-v3-core/contracts/libraries/TickBitmap.sol:42: function nextInitializedTickWithinOneWord(`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:432: tickBitmap.flipTick(tickLower, tickSpacing);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:435: tickBitmap.flipTick(tickUpper, tickSpacing);`
- `lib/uniswap-v3-core/contracts/UniswapV3Pool.sol:646: (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(`

Notes:
- This is the topology-heavy version of fee farming and often matters on custom forks with small spacing.
