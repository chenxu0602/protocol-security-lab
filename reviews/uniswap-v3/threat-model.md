# Threat Model

## Protocol Summary
Uniswap V3 is a concentrated-liquidity AMM. Liquidity providers define positions over bounded tick ranges, and swaps execute against the current active liquidity within the current price range. Within a single active tick range, swap execution follows the constant-product-style sqrt-price/liquidity math; across initialized ticks, active liquidity changes through tick crossing.

The pool must correctly maintain:
- current sqrt price and current tick
- active liquidity
- position liquidity and owed tokens
- tick boundary state
- LP fee growth and protocol fee accrual
- oracle observations and cumulative state

## Actors
- Factory owner
- Pool initializer
- Liquidity provider
- Swapper
- Position owner
- Protocol fee collector
- External callback caller / router
- Oracle / observation consumer

## Trust Assumptions
- ERC20 tokens used by the pool behave sufficiently like expected ERC20s for balance and transfer operations.
- The initial pool price is chosen by the initializer and may be economically poor, but this is not itself a core pool logic failure.
- The factory owner may enable fee tiers and set protocol fee parameters, but should not be able to violate pool accounting invariants.
- External parties implementing mint/swap/flash callbacks are untrusted and must be validated through pool-side balance checks rather than trusted behavior.

## External Trust Boundaries
- External token contracts
- Callback recipients and callback callers
- Factory-controlled protocol fee configuration
- Pool initialization price choice
- External integrators relying on observations / TWAP

## Assets / Security Properties to Protect
- Correct current active liquidity for the current tick range
- Correct swap execution without overshooting the selected step boundary or price limit
- Correct token0/token1 inventory decomposition for positions above range, in range, and below range
- Correct fee allocation between LPs and protocol
- Correct conversion of accrued fees into position-level owed balances
- Correct oracle observation growth, writes, and cumulative accounting
- Correct settlement after mint/swap/flash callbacks through balance-before / balance-after checks

## Accounting Anchors
- `slot0` must consistently represent the current pool execution state
- `liquidity` must equal the current active liquidity, not the sum of all position liquidities
- `liquidityGross` and `liquidityNet` must correctly encode tick-boundary effects
- New fee accrual in each swap step must be attributed only to liquidity active during that step
- `feeGrowthInside` reconstruction must be consistent with lower/upper tick outside accumulators
- `tokensOwed{0,1}` must only reflect amounts already crystallized to the position
- `tickCumulative` and `secondsPerLiquidityCumulativeX128` must evolve consistently with swap progression and observation writes

## Main Review Surfaces
- Pool global state transitions through `slot0`
- Position lifecycle: mint, burn, collect, and internal position updates
- Tick lifecycle: initialization, crossing, bitmap flipping, and cleanup
- Swap step math, price movement, and exact-input / exact-output behavior
- Fee accrual, fee growth accounting, and protocol fee extraction
- Observation writes, cumulative oracle values, and inside/outside reconstruction
- Callback-based settlement for mint, swap, and flash

## Main Threat Surfaces
- Incorrect tick crossing directionality under `zeroForOne` versus `oneForZero`
- Incorrect sign handling of `liquidityNet` during leftward vs rightward crossing
- Rounding errors in swap-step math causing excess output, insufficient input collection, or boundary overshoot
- Inconsistent token0/token1 delta usage relative to current price and position range state
- Drift between active liquidity and tick/position boundary accounting
- Incorrect fee growth updates under changing active liquidity
- Incorrect separation between LP fees and protocol fees
- Observation write timing causing inconsistent cumulative state or distorted TWAP reads
- Inconsistent outside/inside accumulator initialization or crossing updates
- Callback settlement failures or insufficient post-callback balance checks
- Ordering issues between state updates, fee crystallization, and owed-token accounting

## High-Value Review Questions
- Does each swap step remain within the correct target boundary and price limit?
- Is current active liquidity updated exactly when initialized ticks are crossed, and only then?
- Are lower and upper ticks updated with the correct signed liquidity effects?
- Do in-range, below-range, and above-range positions require the correct token0/token1 amounts when minting or burning?
- Are fees accrued only to the liquidity that was active during the relevant swap step?
- Are `feeGrowthGlobal`, `feeGrowthInside`, and `tokensOwed` connected without leakage or double counting?
- Are observation writes triggered at the correct state transition points?
- Can any callback path cause underpayment while still satisfying pool-side checks?
- Are protocol fee settings and withdrawals unable to corrupt LP accounting?