# Curve StableSwap Test Plan

## Scope
This test plan is derived from:
- `curve-contract-threat-model.md`
- `stableswap-ng-threat-model.md`
- `curve-stableswap-function-notes.md`
- `curve-stableswap-invariants.md`

Priority is:
1. StableSwap NG core correctness
2. StableSwap NG deployment / asset-type / rate-provider safety
3. Legacy regression backstops for the accounting models that differ from NG

## 1. Test Strategy

### 1.1 Test layers
- Unit / deterministic tests
  - fixed-state checks for math, fees, rates, and routing behavior

- Stateful scenario tests
  - multi-step flows such as donation -> quote -> swap -> withdraw

- Differential tests
  - compare quote helpers with execution under unchanged state

- Configuration-negative tests
  - ensure invalid pool deployments or unsafe mode combinations revert

- Invariant / fuzz-style tests
  - randomized sequences over deposits, swaps, withdrawals, rebases, donations, and rate updates

### 1.2 Primary goals
- prove NG asset-type handling is self-consistent
- prove `stored_rates -> xp -> D -> LP supply / virtual price` remains coherent
- prove views are directionally consistent with execution
- prove proportional exit remains the least-fragile solvent exit
- catch legacy wrapper/metapool/ETH regressions while focusing effort on NG

### 1.3 Characterization vs vulnerability tests
Some tests should document intended behavior rather than assert vulnerability.

Examples:
- direct donation may increase virtual price or become pool surplus
- `exchange_received` may consume existing surplus under optimistic-transfer semantics
- `MetaZapNG` may transfer pre-existing dust to the current caller if it uses `balanceOf(self)`
- oracle-rate misconfiguration may demonstrate unsafe deployment assumptions rather than a pool-code bug

A behavior becomes reportable only when it violates documented assumptions, breaks slippage protection, causes value transfer, dilutes LPs, traps funds, or enables unsafe factory-created pools.

## 2. StableSwap NG Test Matrix

### 2.1 Factory deployment validation

#### Objective
- Reject syntactically unsafe pool configurations.

#### Test cases
- `deploy_plain_pool` rejects:
  - fewer than 2 coins
  - mismatched array lengths
  - duplicate coins
  - decimals > 18
  - invalid implementation index
  - invalid fee
  - invalid `offpeg_fee_multiplier * fee` bound

- `deploy_metapool` rejects:
  - unregistered base pool
  - invalid implementation index
  - invalid fee bounds
  - forbidden base-asset pairing with base LP token
  - decimals > 18 for meta coin

#### Useful assertions
- pool registry and market mappings are updated exactly once
- stored metadata (`coins`, `decimals`, `asset_types`, `base_pool`) matches deployed intent

### 2.2 Asset type correctness

#### Objective
- Prove asset type drives the intended accounting branch.

#### Plain asset tests
- plain ERC20 uses no external oracle semantics
- direct donations affect accounting only in ways intended by the plain-asset model

#### Oracle asset tests
- correct oracle precision gives expected `stored_rates`
- wrong-direction or wrong-scale mock oracle produces observable mispricing and is documented as unsafe configuration behavior
- reverted oracle call reverts dependent path

#### ERC4626 asset tests
- `stored_rates` reflects vault share/asset conversion
- donation to the vault changes share price and therefore pool pricing in the expected direction
- preview/convert mismatch scenarios are surfaced in quote vs execution tests

#### Rebasing asset tests
- rebasing token balance changes without transfer
- `stored_balances` vs actual balances remain explainable under rebasing semantics
- `exchange_received` is disabled when rebasing asset type is configured

### 2.3 Stored rates and normalization

#### Objective
- Validate `stored_rates()` and `xp` reconstruction under all NG asset models.

#### Test cases
- plain pools: `stored_rates` equals expected multiplier-only normalization
- oracle pools: rate updates feed directly into `xp`
- ERC4626 pools: share price update changes `xp` and virtual price coherently
- rebasing pools: raw `balanceOf(pool)` change interacts safely with stored balances

#### Assertions
- `xp` changes are explainable from:
  - raw balances
  - stored balances
  - rate multipliers
  - rate providers / ERC4626 conversions

### 2.4 LP supply / `D` / virtual price coherence

#### Objective
- Ensure mint/burn and virtual price remain coherent with invariant `D`.

#### Test cases
- initial liquidity bootstrap
- balanced deposit
- imbalanced deposit
- proportional withdrawal
- one-coin withdrawal
- donation to pool
- donation to ERC4626 vault backing the pool
- rebasing balance increase

#### Assertions
- LP minted is monotonic with fee-adjusted `D` growth
- LP burned is coherent with `D` reduction
- `get_virtual_price()` is explainable from current pool economics
- donation-sensitive virtual price jumps are either intended or bounded/documented

### 2.5 Swap settlement

#### Objective
- Ensure input, output, fee retention, and admin fee accounting reconcile.

#### Test cases
- balanced swap
- off-peg swap
- just-before and just-after dynamic fee regime transitions
- swap after external rate update
- swap after donation / rebasing event

#### Assertions
- output amount matches execution path expectations
- admin fee stays in raw token units
- `admin_balances[i]` never exceeds coin balance
- stored balance / raw balance transitions remain explainable

### 2.6 `exchange_received`

#### Objective
- Characterize optimistic prior-transfer settlement and ensure it is disabled or safe under rebasing semantics.

#### Test cases
- valid prior-transfer swap in plain/oracle/ERC4626 pools
- revert when rebasing asset type is present
- historical surplus in pool before user call
- donation before `exchange_received`
- rebasing drift between prior transfer and call

#### Assertions
- input recognized by the pool corresponds to intended user contribution
- historical surplus behavior is characterized explicitly
- if surplus can be consumed by the current caller, this must be documented and must not break user slippage assumptions
- rebasing drift cannot be consumed as swap input

### 2.7 Views contract: quote/execution consistency

#### Objective
- Treat views as an economic API and compare them with execution.

#### `get_dy`
- compare quote vs real execution under unchanged state
- repeat near off-peg boundaries
- repeat after oracle/rate updates

#### `get_dx`
- compare reverse quote vs actual required input
- emphasize dynamic-fee paths, where reverse quote may be more approximate
- require slippage buffer in router-style tests

#### `calc_token_amount`
- compare deposit/withdraw quote vs actual LP mint/burn

#### `calc_withdraw_one_coin`
- compare quote vs one-coin withdrawal execution

#### Underlying metapool views
- compare `get_dy_underlying` / `get_dx_underlying` with real nested execution
- test stale vs freshly-updated base-pool rate, virtual-price, or stored-rate situations where applicable

### 2.8 Dynamic fee behavior

#### Objective
- Ensure fee rises smoothly and economically when imbalance increases.

#### Test cases
- equal balances
- mild imbalance
- severe imbalance
- state transition across dynamic fee regime

#### Assertions
- fee near base fee when symmetric
- fee non-decreasing as imbalance worsens, within intended regime
- no pathological discontinuity that invalidates standard slippage protections

### 2.9 Proportional exit safety

#### Objective
- Prove `remove_liquidity` remains the least-fragile solvent exit.

#### Test cases
- after donation
- after rebasing increase
- after oracle update
- after failed `exchange_received` attempt
- after metapool nested activity

#### Assertions
- proportional exit remains available in degraded but solvent states
- ordinary LP exits do not depend on unrelated historical dust or admin surplus

### 2.10 MetaZapNG temporary custody

#### Objective
- Ensure nested routing does not contaminate caller outcomes with historical zap balances.

#### Test cases
- add liquidity with only meta asset
- add liquidity with only base assets
- add liquidity with mixed assets
- remove one coin into base underlying
- remove liquidity imbalance across nested path
- manually seed zap with dust/base LP before user call

#### Assertions
- temporary custody is consumed, returned, or explainable as dust
- `balanceOf(self)` reads are characterized and do not create unintended value transfer or trapped funds
- leftover base LP does not remain stranded unintentionally

## 3. Legacy Backstop Tests

### 3.1 Plain legacy pools
- direct donation vs `self.balances`
- `remove_liquidity` safety vs one-coin and imbalance exits
- admin fee reconciliation in raw token units

### 3.2 Legacy metapools
- `_vp_rate` vs `_vp_rate_ro`
- cache-valid vs expired-cache vs refreshed execution
- `get_dy_underlying` approximation vs actual `exchange_underlying`

### 3.3 Y-style pools
- wrapper share-price changes
- `get_dy` vs `get_dy_underlying`
- zap unwrap residuals

### 3.4 Compound-style pools
- `_stored_rates()` approximation vs `_current_rates()` execution
- cToken route vs underlying route equivalence
- `self.balances` vs actual cToken balance after redemption/donation

### 3.5 Aave-style pools
- direct aToken route vs underlying route
- live balance accounting and dynamic fee
- donation/yield entering `D` and `virtual_price`

### 3.6 ETH pools
- callback reentrancy around `exchange`
- callback reentrancy around withdrawal paths
- state-finalization-before-send

### 3.7 Legacy zaps
- leftover balances after nested operations
- fee-on-transfer token handling
- base-LP dust contamination

## 4. Suggested Tooling

### NG
- existing pytest suite in `stableswap-ng/tests`
- additional dedicated mocks for:
  - bad oracle precision
  - discontinuous oracle rates
  - ERC4626 donation behavior
  - rebasing drift between quote and execution
  - dust contamination in zap

### Legacy
- existing brownie-based pool tests
- focused regression tests against:
  - metapool cache behavior
  - wrapper accounting differences
  - ETH reentrancy

### Optional fuzz / property testing
- repeated randomized sequences:
  - deposit
  - swap
  - donation
  - rebase
  - quote
  - withdraw
- invariant checks after each step:
  - LP supply / `D` coherence
  - admin balance bound
  - solvency of proportional exit

## 5. Priority Order

### P0: Math / reference tests
- Python `get_D` / `get_y` / `get_y_D` vs Vyper implementation or harness
- `D` symmetry and monotonicity
- larger `A` lowers near-peg slippage

### P1: Dynamic fee tests
- balanced fee is approximately base fee
- imbalanced fee increases
- views `get_dy` matches the intended fee formula closely enough for safe routing

### P2: `exchange_received` characterization
- valid pre-transfer path
- surplus pre-seeded before caller action
- rebasing-disabled path

### P3: Asset-type mocks
- mock oracle rate precision / direction issues
- mock ERC4626 `convertToAssets` donation effect
- mock rebasing balance drift

### P4: `MetaZapNG` dust / leftover characterization
- pre-seeded dust
- historical base-LP leftovers
- `balanceOf(self)` contamination checks

## 6. Exit Criteria

This review track should be considered meaningfully exercised when:
- NG factory rejects all syntactically invalid configurations we can model
- NG asset-type branches each have direct scenario coverage
- NG quotes are checked against execution on plain, oracle, ERC4626, rebasing, and metapool routes
- NG `exchange_received` is stress-tested against surplus/rebasing edge cases
- NG proportional exit is validated after adversarial balance changes
- legacy metapool, wrapper, Aave, Compound, and ETH edge cases each have at least one targeted regression test
