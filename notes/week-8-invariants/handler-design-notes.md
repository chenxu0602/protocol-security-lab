# Handler Design Notes

## General design rules
- bounded actor set
- bounded action space
- avoid meaningless random calls
- preserve useful state history
- prefer economically meaningful transitions over full API coverage

---

## Morpho Blue

### Objective
Design a bounded handler for solvency, liquidity, and liquidation invariants.

Main invariants to support:
- healthy position cannot be liquidated
- successful borrow-side transitions should preserve recorded liquidity bounds

### Why Morpho Blue is suitable
Morpho Blue is a good invariant target because:
- the protocol has a relatively clean lending state machine
- solvency and liquidation conditions are economically meaningful and durable
- many transitions can be expressed with bounded actor/action sets
- interest accrual can be introduced explicitly through time warp

### Actor set
Use a small fixed actor set:
- supplier1
- supplier2
- borrower1
- borrower2
- liquidator

Optional:
- allocator / passive actor if needed for additional liquidity diversity

Design rule:
- keep actors fixed and known
- avoid generating arbitrary addresses
- map fuzzed actor index into this fixed set

### Market scope
Use one market only for the first version:
- one loan asset
- one collateral asset
- one oracle price path
- one LLTV configuration

Do not start with multi-market invariants.

### Action set
Initial handler actions:
- supply
- supplyCollateral
- borrow
- repay
- withdrawCollateral
- withdrawSupply
- liquidate
- warp

Optional later:
- setPrice (if using a mocked oracle)
- repayAll / borrowMax helpers

### Why these actions
- `supply`: creates liquidity and supplier-side accounting
- `supplyCollateral`: changes borrower solvency without changing loan-side liquidity
- `borrow`: exercises core liability creation path
- `repay`: exercises debt reduction path
- `withdrawCollateral`: exercises solvency boundary
- `withdrawSupply`: exercises liquidity boundary
- `liquidate`: directly tests health/insolvency semantics
- `warp`: forces interest accrual and allows health state transitions over time

### Excluded actions for first pass
Do not include in the first version:
- arbitrary authorization/delegation paths
- multiple markets
- extreme administrative configuration changes
- complicated helper wrappers

Reason:
- Week 8 goal is invariant training, not exhaustive protocol harnessing

### Parameter bounds
All actions should be bounded to avoid meaningless noise.

#### supply
- actor must have mintable loan asset balance
- amount bound to:
  - actor token balance
  - some protocol-level max, e.g. `MAX_SUPPLY`

#### supplyCollateral
- actor must have mintable collateral balance
- amount bound to:
  - actor collateral balance
  - `MAX_COLLATERAL`

#### borrow
Bound requested amount by:
- available market liquidity
- a conservative fraction of max borrowable amount if computable
- otherwise use `bound(amount, 0, MAX_BORROW_TRY)` and allow revert-catching

Design preference:
- do not force every borrow to succeed
- but avoid obviously nonsense borrow sizes

#### repay
Bound requested amount by:
- current borrower debt if known
- actor loan asset balance
- allow partial repay

#### withdrawCollateral
Bound requested amount by:
- current posted collateral
- possibly conservative fraction of current collateral to reduce revert spam

#### withdrawSupply
Bound requested amount by:
- supplier share/asset position if tracked
- available liquidity if computable

#### liquidate
Bound requested repay/seize size by:
- current borrower debt
- liquidator asset balance
- use a small number of target borrowers rather than arbitrary borrower selection

#### warp
Bound time jump to a reasonable range, for example:
- 1 hour to 30 days
Avoid huge random jumps that make debugging difficult.

### Oracle / price handling
Use a mocked oracle.

Two possible modes:

#### Mode A: fixed price
- simplest first version
- useful for liquidity-bound invariants
- not enough for full liquidation testing

#### Mode B: bounded price moves
- allow price decreases/increases within a bounded range
- needed to test healthy vs unhealthy liquidation paths

Recommendation:
- start with fixed price for liquidity invariant
- then add bounded price moves for liquidation invariant

### Ghost variables
Use a small number of ghost variables only if they help invariants.

Recommended first ghost variables:
- `lastKnownHealthy[borrower]`
- `successfulBorrowCount`
- `successfulLiquidationCount`
- `netExternalLoanAssetIn`
- `netExternalLoanAssetOut`

Possible later:
- expected liquidity lower bound approximation
- last observed debt/collateral snapshot per borrower

Design rule:
- ghost variables should explain protocol behavior
- do not mirror the entire protocol state in ghosts

### Revert policy
Very important.

Not every random action should be required to succeed.

Use this policy:
- expected economic invalid actions may revert
- unexpected successful actions are often more interesting than expected reverts
- invariants should be checked after any successful state transition
- where possible, record whether an action succeeded

Examples:
- over-borrow may revert -> acceptable
- withdrawing too much collateral may revert -> acceptable
- liquidating a healthy position succeeding -> suspicious

### Success tracking
Track whether actions succeed:
- successful supply
- successful borrow
- successful repay
- successful withdraw
- successful liquidation

This helps distinguish:
- no invariant signal because nothing happened
- invariant signal after meaningful state transitions

### Candidate invariant 1
#### healthy position cannot be liquidated
Natural-language form:
- if a borrower is healthy under current price/oracle conditions, liquidation should not succeed

Handler support needed:
- borrower collateral/debt positions
- mocked oracle
- bounded price updates or time warp
- liquidation attempts against tracked borrowers

Caution:
- health should be checked using protocol-consistent logic
- avoid hand-rolled “healthy” definitions unless carefully aligned with protocol semantics

### Candidate invariant 2
#### successful borrow-side transitions preserve recorded liquidity bounds
Natural-language form:
- after successful supply/borrow/repay/withdraw transitions, recorded borrow assets should not exceed what protocol accounting can support

Handler support needed:
- meaningful supply and borrow activity
- some way to read market totals
- post-step assertion on total supply / total borrow relationship or other chosen liquidity bound

Caution:
- define this invariant using Morpho’s recorded accounting, not naive wallet balances

### First implementation plan
Build in this order:

1. fixed actor set
2. supply / supplyCollateral / borrow / repay / warp
3. add withdrawCollateral / withdrawSupply
4. add liquidate
5. start with one invariant:
   - healthy position cannot be liquidated
6. then add second invariant:
   - borrow-side transitions preserve liquidity bounds

### What to avoid in v1
- multi-market handler
- too many actors
- too many ghost variables
- trying to prove every accounting identity at once
- mixing authorization testing into solvency/liquidity invariants

### Desired result
By the end of the first Morpho handler version, the harness should:
- generate economically meaningful lending state transitions
- explore solvency boundaries
- attempt liquidations in both healthy and unhealthy states
- support at least one hard invariant and one accounting-bound invariant
- remain debuggable when a failure occurs


## Concrete v1 handler choice

### Scope
This first handler version is intentionally narrow.

Use:
- one Morpho Blue market
- one loan asset
- one collateral asset
- one mocked oracle
- fixed LLTV and IRM configuration
- fixed actor set

Do not include:
- multiple markets
- authorization/delegation paths
- complex admin/config changes
- multiple collateral types

### Actors
Use four actors only:
- supplier1
- borrower1
- borrower2
- liquidator

Optional:
- supplier2 can be added later if more liquidity diversity is needed

### Actions in v1
Include only:
- `supply(uint256 actorSeed, uint256 amountSeed)`
- `supplyCollateral(uint256 actorSeed, uint256 amountSeed)`
- `borrow(uint256 actorSeed, uint256 amountSeed)`
- `repay(uint256 actorSeed, uint256 amountSeed)`
- `liquidate(uint256 targetSeed, uint256 amountSeed)`
- `warp(uint256 timeSeed)`

Deferred to v2:
- `withdrawSupply`
- `withdrawCollateral`
- `setPrice`
- explicit bad-debt stress paths
- delegate / authorization paths

### Actor mapping
Map fuzzed seeds into fixed actors:
- suppliers: supplier1 only in v1
- borrowers: borrower1 or borrower2
- liquidator: fixed liquidator address

Recommended mapping:
- `actorSeed % 2 == 0` -> borrower1
- `actorSeed % 2 == 1` -> borrower2

For `supply`, always use `supplier1` in v1.

Reason:
- reduces meaningless combinations
- improves debuggability
- still explores meaningful state transitions

### Action details

#### 1. supply
Signature:
- `supply(uint256 amountSeed)`

Caller:
- `supplier1`

Purpose:
- creates available liquidity for borrowers
- exercises supplier-side accounting and total supply growth

Bound:
- amount should be bounded into a reasonable nonzero range
- for example:
  - minimum: small dust floor or 1
  - maximum: `MAX_SUPPLY`

Additional rule:
- mint loan asset to supplier1 before the call if your test scaffold allows it
- approve Morpho before supply

Expected behavior:
- may almost always succeed if bounded sanely
- failures should be rare and investigated

#### 2. supplyCollateral
Signature:
- `supplyCollateral(uint256 actorSeed, uint256 amountSeed)`

Caller:
- borrower selected from actorSeed

Purpose:
- changes borrower health without affecting loan-side liquidity
- creates states where borrow and liquidation become meaningful

Bound:
- minimum nonzero floor
- maximum: `MAX_COLLATERAL`

Additional rule:
- mint collateral asset to borrower before the call if scaffold allows
- approve Morpho before supplyCollateral

Expected behavior:
- should usually succeed

#### 3. borrow
Signature:
- `borrow(uint256 actorSeed, uint256 amountSeed)`

Caller:
- borrower selected from actorSeed

Purpose:
- exercises solvency and liquidity boundary
- creates debt positions for future repay or liquidation

Bound strategy:
- do not attempt exact max borrow in v1
- use a conservative bound:
  - requested amount in `[0, MAX_BORROW_TRY]`
- allow revert if:
  - insufficient collateral
  - insufficient market liquidity

Optional better bound:
- if easy to compute, bound by a fraction of max borrowable amount from current collateral and oracle price

Expected behavior:
- some borrows will revert and that is acceptable
- successful borrows are the important transitions for invariants

#### 4. repay
Signature:
- `repay(uint256 actorSeed, uint256 amountSeed)`

Caller:
- borrower selected from actorSeed

Purpose:
- reduces debt
- exercises debt accounting and borrow-side reversibility

Bound:
- if borrower has no debt, return early
- otherwise bound repay request by:
  - borrower current debt
  - borrower loan token balance
- partial repay is enough in v1

Additional rule:
- mint loan asset to borrower before repay if scaffold allows
- approve Morpho before repay

Expected behavior:
- should usually succeed when debt exists

#### 5. liquidate
Signature:
- `liquidate(uint256 targetSeed, uint256 amountSeed)`

Caller:
- liquidator

Target:
- borrower1 or borrower2 selected from targetSeed

Purpose:
- directly probes the main solvency invariant
- distinguishes healthy from unhealthy liquidation states

Bound:
- if target has no debt or no collateral, return early
- requested liquidation amount bounded by:
  - target debt
  - liquidator available loan asset balance
  - conservative liquidation cap if needed

Additional rule:
- mint loan asset to liquidator before liquidation if scaffold allows
- approve Morpho before liquidation

Expected behavior:
- liquidation of unhealthy positions may succeed
- liquidation of healthy positions should not succeed

Important:
- this is one of the main signal-producing actions in v1

#### 6. warp
Signature:
- `warp(uint256 timeSeed)`

Purpose:
- accrues interest
- changes solvency over time without price changes
- creates liquidation opportunities through debt growth

Bound:
- use a moderate range only
- e.g. from 1 hour to 30 days

Recommended bound:
- `dt = bound(timeSeed, 1 hours, 30 days)`

Expected behavior:
- should always succeed
- interest accrual should be one of the key drivers of state diversity

### Oracle / price policy in v1
Keep oracle price fixed in v1.

Reason:
- isolates time-accrual solvency changes
- makes failures easier to interpret
- still allows unhealthy states to arise via debt growth

Do not add price mutation until v1 works.

Add price-changing actions only in v2.

### Revert policy
Reverts are acceptable for economically invalid actions.

Treat as acceptable:
- borrow without enough collateral
- borrow without enough liquidity
- repay with zero debt
- liquidate healthy account
- liquidate with no target debt/collateral

But note:
- repeated revert spam means bounds are poor
- v1 should still generate many successful state transitions

### Success accounting
Track simple success counters in the handler:

- `successfulSupplies`
- `successfulCollateralSupplies`
- `successfulBorrows`
- `successfulRepays`
- `successfulLiquidations`
- `totalWarps`

Why:
- helps check whether the harness is exploring meaningful states
- helps debug “invariant passed only because nothing happened”

### Minimal ghost variables
Use only a few in v1:

- `lastActionSucceeded`
- `successfulBorrows`
- `successfulLiquidations`
- maybe `lastKnownHealthy[target]` if you can compute health cleanly

Do not mirror full protocol state.

### v1 invariant support

#### Invariant A
`healthy position cannot be liquidated`

Needed support:
- fixed price
- time warp
- borrower debt/collateral reads
- liquidation attempts

Interpretation:
- if protocol health logic says account is healthy, liquidation should not succeed

#### Invariant B
`successful borrow-side transitions preserve recorded liquidity bounds`

Needed support:
- meaningful supply, borrow, repay activity
- market total reads
- assertion after successful state transitions

Interpretation:
- successful transitions should not leave recorded borrow assets in a state inconsistent with recorded supply-side liquidity bounds

### Recommended implementation order
1. build actor setup and approvals
2. implement `supply`
3. implement `supplyCollateral`
4. implement `borrow`
5. implement `repay`
6. implement `warp`
7. add `liquidate`
8. write invariant A first
9. then write invariant B

### Debugging preference
Prefer a harness that is small and explainable over one that is broad.

A good v1 result is:
- many successful transitions
- some expected reverts
- at least one hard solvency invariant running reliably

A bad v1 result is:
- huge action set
- almost everything reverts
- difficult-to-interpret failures