# Function Notes

## Factory Layer

### createPool(address tokenA, address tokenB, uint24 fee)
- Sorts token pair into canonical `token0` / `token1`
- Rejects identical tokens, zero address, unsupported fee tier, and duplicate pool creation
- Deploys the canonical pool through `UniswapV3PoolDeployer`
- Populates `getPool` in both token orders for lookup convenience
- Main review focus:
  - uniqueness of `(token0, token1, fee) -> pool`
  - fee-tier gating and tick-spacing consistency
  - deterministic canonical pool identity

### setOwner(address _owner)
- Only current factory owner can call
- Transfers factory governance authority
- Main review focus:
  - owner handoff is simple but controls fee-tier enablement and protocol-fee governance

### enableFeeAmount(uint24 fee, int24 tickSpacing)
- Only factory owner can call
- Adds a new fee tier and fixed tick spacing
- Enforces one-time enablement and bounded tick spacing
- Main review focus:
  - custom fee tiers must not break tick bitmap search assumptions
  - tick spacing must remain compatible with max-liquidity-per-tick and tick arithmetic bounds

## Deployment Layer

### deploy(address factory, address token0, address token1, uint24 fee, int24 tickSpacing)
- Temporarily stores constructor parameters in deployer storage
- Deploys the pool with CREATE2 salt derived from `(token0, token1, fee)`
- Clears transient parameters after deployment
- Main review focus:
  - constructor parameter handoff must be race-free and self-consistent
  - deterministic address derivation must match canonical pool identity assumptions

## Pool Setup / Oracle Layer

### increaseObservationCardinalityNext(uint16 observationCardinalityNext)
- Grows oracle observation capacity for future writes
- Updates only the next target cardinality, not the current populated size
- Main review focus:
  - cardinality growth should not corrupt ordering, indexing, or historical observations

### initialize(uint160 sqrtPriceX96)
- One-time pool initialization
- Derives initial tick from the provided sqrt price
- Initializes oracle storage and unlocks the pool
- Main review focus:
  - initialization may choose a poor economic start price, but should not violate core accounting invariants
  - initial tick / sqrt price / observation state must be mutually consistent

### observe(uint32[] secondsAgos)
- Reads cumulative oracle values at requested lookback offsets
- Returns global `tickCumulative` and `secondsPerLiquidityCumulativeX128` snapshots
- Main review focus:
  - observation interpolation / lookup should remain path-consistent
  - returned cumulative values should support safe TWAP-style differencing

### snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
- Reconstructs cumulative values inside a position range using lower/upper tick outside accumulators plus current/global cumulative state
- Requires both boundary ticks to be initialized
- Main review focus:
  - inside/outside reconstruction must match current tick location
  - lower/upper boundary accounting must remain consistent across tick crossings

## Position Lifecycle

### _modifyPosition(ModifyPositionParams memory params)
- Shared internal path for liquidity add/remove
- Validates ticks, updates tick state, reconstructs `feeGrowthInside`, and settles the position
- Returns signed token deltas implied by the position change
- Main review focus:
  - ordering between tick updates, fee crystallization, oracle writes, and token delta calculation
  - current-price-relative inventory decomposition (below range / in range / above range) must match token delta outputs

### _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick)
- Touches lower and upper ticks only, because the position is encoded by boundary effects rather than per-tick writes
- Flips bitmap entries when initialization status changes
- Computes range `feeGrowthInside` using current tick and lower/upper tick outside state
- Updates the position checkpoint and clears no-longer-needed ticks on liquidity removal
- Main review focus:
  - lower/upper sign handling and `liquidityNet` encoding
  - tick flip cleanup and bitmap consistency
  - inside/outside fee reconstruction
  - lazy fee crystallization into `tokensOwed`

### mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes data)
- Adds liquidity for `recipient` through `_modifyPosition`
- Calls external mint callback to collect owed token amounts
- Verifies post-callback balances rather than trusting callback behavior
- Main review focus:
  - callback settlement and underpayment resistance
  - correct required token amounts above / in / below range
  - balance-before / balance-after checks
  - ownership recipient vs callback caller separation

### collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested)
- Withdraws already-crystallized `tokensOwed`
- Does not recompute fees by itself
- Caps payout at recorded owed balances
- Main review focus:
  - users must not assume `collect` alone updates fee state
  - fee settlement happens through position updates, then `collect` performs withdrawal only
  - collectable balances must not exceed previously crystallized amounts

### burn(int24 tickLower, int24 tickUpper, uint128 amount)
- Removes liquidity through `_modifyPosition`
- Converts returned signed deltas into positive owed token balances
- Does not transfer tokens immediately; amounts become collectible through `collect`
- `burn(0)` can be used to crystallize accrued fees without changing liquidity
- Main review focus:
  - burn both removes liquidity and crystallizes owed principal/fees into `tokensOwed`
  - signed delta direction must be consistent with pool-to-user settlement semantics

## Swap / Fee Layer

### swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes data)
- Main execution loop for exact-input and exact-output swaps
- Repeatedly finds the next initialized tick, computes a swap step, updates fee growth, and crosses ticks as needed
- Writes oracle observations only if tick changes across the swap
- Pays output before callback, then enforces input repayment via balance checks
- Main review focus:
  - step-boundary correctness
  - price-limit enforcement
  - exact-input / exact-output sign and amount mapping
  - tick crossing directionality
  - active liquidity updates through `liquidityNet`
  - fee growth attribution only to liquidity active during each step
  - callback underpayment resistance

### flash(address recipient, uint256 amount0, uint256 amount1, bytes data)
- Sends tokens out optimistically, then requires repayment plus fee in callback
- Splits paid fees between protocol and LP fee growth
- Requires nonzero in-range liquidity before allowing flash
- Main review focus:
  - repayment checks
  - rounding-up fee computation
  - consistency with LP/protocol fee accounting
  - actual paid amounts, not only nominal fees, drive fee accrual

## Governance Fee Layer

### setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1)
- Only factory owner can call
- Sets protocol fee denominators for token0 and token1
- Main review focus:
  - configuration bounds
  - correct packing/unpacking into `slot0.feeProtocol`
  - separation of protocol skim from LP fee growth

### collectProtocol(address recipient, uint128 amount0Requested, uint128 amount1Requested)
- Only factory owner can call
- Withdraws accrued protocol fees up to requested amounts
- Intentionally leaves one unit behind when fully draining a slot for gas savings
- Main review focus:
  - protocol withdrawal must not touch LP-owned accounting
  - protocol fee balances must remain disjoint from LP fee growth / position fee entitlement

## Small But Important Guards

### lock
- Reentrancy / execution-order guard used on state-changing entry points
- Prevents callback-driven interleaving from violating pool state assumptions
- Main review focus:
  - callback-based control flow must not bypass state-machine sequencing

### noDelegateCall
- Used on selected sensitive entry points
- Ensures execution happens in the pool or factory context, not through delegatecall
- Main review focus:
  - protects assumptions around storage layout and execution context