# Curve StableSwap / StableSwap NG Final Review

## 1. Scope

This is a focused research review and characterization pass, not a full protocol audit.

- StableSwap NG core math and accounting
- asset-type / rate-provider semantics
- rebasing-token handling
- quote vs execution behavior
- `exchange_received`
- admin-fee unit accounting
- MetaZapNG temporary custody
- selected legacy StableSwap references

Out of scope:
- full production deployment review
- complete factory governance review
- full gauge/reward review
- exhaustive legacy pool family review

## 2. Core Mental Model

StableSwap accounting spine:

`balances -> stored_rates -> xp -> D / y -> LP supply / virtual price`

NG extends this with:

- asset types
- rate oracles
- ERC4626 conversion
- rebasing balance drift
- dynamic fees
- Views contract
- MetaZapNG nested routing

The main review question is not only whether invariant math is correct, but whether the pool applies the correct economic interpretation before values ever reach the invariant solver.

## 3. Main Review Conclusions

### 3.1 StableSwap math kernel is legacy-like

`get_D`, `get_y`, and `get_y_D` preserve the classic StableSwap invariant behavior.

Tests covered:
- zero-balance `D`
- balanced-pool `D ≈ sum(xp)`
- symmetry
- monotonicity
- `get_y` preserving `D`
- larger `A` reducing near-peg slippage
- `get_y_D` behavior under reduced target `D`

Conclusion:
- The main NG risk is not the invariant solver itself.
- The main risk is what gets fed into the solver: `stored_balances`, `stored_rates`, `xp`, and asset-type interpretation.

### 3.2 Dynamic fee behaves as off-peg fee amplification

Tests covered:
- balanced pool returns base fee
- disabled multiplier returns base fee even when imbalanced
- imbalanced pool produces higher fee

Conclusion:
- Dynamic fee is economically coherent at the formula level.
- Review focus should be on whether inputs are comparable `xp` balances and whether quote/execution use consistent fee inputs.

### 3.3 Asset type is the primary NG semantic boundary

Plain assets:
- use multiplier-only normalization

Oracle assets:
- rely on external rate precision and direction
- wrong-scale oracle can produce internally consistent but economically wrong `xp`

ERC4626 assets:
- `convertToAssets` directly affects `stored_rates`
- vault donation changes share price and therefore pool pricing

Rebasing assets:
- actual `balanceOf(pool)` can drift from `stored_balances`
- rebasing pools must disable `exchange_received`

Conclusion:
- Asset type misconfiguration is one of the highest-value NG review surfaces.

### 3.4 `exchange_received` is optimistic-transfer settlement, not sender-bound transfer accounting

Tests characterized:
- prior transfer is consumed as input
- historical surplus can be consumed by the current caller
- post-sync donation merges with caller input
- rebasing asset presence disables the path
- rebasing drift cannot be consumed as swap input
- real NG plain pool `exchange_received` matches quote under unchanged state
- real NG rebasing pool `exchange_received` reverts

Conclusion:
- For non-rebasing assets, surplus consumption is a documented semantic boundary, not automatically a vulnerability.
- For rebasing assets, disabling `exchange_received` is essential.

### 3.5 Quote/execution consistency holds under unchanged state, but rate freshness matters

Tests covered:
- plain pool `get_dy == exchange` under unchanged state
- oracle asset `get_dy == exchange` under unchanged rate
- real NG plain `get_dy == exchange` under unchanged state
- real NG oracle `get_dy == exchange` under unchanged rate
- oracle rate update after quote makes quote stale
- ERC4626 vault donation after quote makes quote stale
- reverse-direction oracle stale quote is observable
- reverse-direction ERC4626 stale quote is observable

Conclusion:
- NG direct quote and execution are consistent under unchanged state.
- Rate-dependent assets create freshness assumptions between quote and execution.
- Routers and integrators must treat quote values as state-dependent and protect with slippage.
- Stale-quote direction is not universally one-sided; it depends on which side carries the changing rate semantics.

### 3.6 Admin fee accounting crosses xp-space and raw token units

Tests covered:
- admin fee computed from `dy_fee_xp` is converted back to raw token units
- higher output rate means fewer raw token units for the same xp fee
- raw/xp conversion roundtrip is rate-consistent

Conclusion:
- `admin_balances[i]` must be interpreted in raw direct-coin units.
- In metapools, coin 1 admin balance is base LP token units, not base underlying units.

### 3.7 Rebasing balance semantics differ from plain asset semantics

Tests characterized:
- plain pool balances use `stored_balances`, not uninternalized actual surplus
- rebasing pool balances gulp actual balance minus admin balance
- plain transfer-out decrements cached stored balance
- rebasing transfer-out rewrites stored balance from actual balance
- proportional exit ignores uninternalized plain donations
- proportional exit reflects rebased balance in rebasing pools

Conclusion:
- `stored_balances` is the accounting source for plain assets.
- actual `balanceOf(pool)` is intentionally reintroduced for rebasing semantics at specific sync points.
- proportional exit remains the least-fragile withdrawal path, but its accounting base differs between plain and rebasing modes.

### 3.8 MetaZapNG is an execution adapter with temporary custody risk

Tests characterized:
- `flush_full_balance` transfers pre-existing dust to current receiver
- historical balance contamination is observable and must be understood as zap semantics

Conclusion:
- MetaZapNG-style full-balance transfer patterns require careful characterization.
- Dust and leftovers are not automatically bugs, but they are a custody and integration risk surface.

## 4. Issue Candidates

### Candidate 1: Unsafe asset-type / oracle-rate configuration

Status:
- Not a code-level issue by itself unless factory accepts objectively invalid configuration or docs make incorrect guarantees.

Risk:
- wrong rate direction or precision can corrupt `xp`
- downstream math remains internally consistent while economically wrong

Evidence:
- mock wrong-scale oracle produces tiny `stored_rates` and tiny `xp`

Likely severity:
- configuration / trust assumption unless permissionless unsafe deployment is possible

### Candidate 2: Quote freshness risk for oracle / ERC4626 assets

Status:
- Characterized behavior.

Risk:
- quotes become stale if rate changes between quote and execution

Evidence:
- oracle rate update after quote changes execution output
- ERC4626 vault donation after quote changes execution output
- reverse-direction stale quotes are also observable

Likely severity:
- informational / integration risk unless a router assumes stale quote without slippage

### Candidate 3: `exchange_received` surplus consumption

Status:
- Characterized behavior.

Risk:
- prior surplus can be consumed by current caller

Evidence:
- historical surplus and current caller input are merged into optimistic input

Likely severity:
- not a vulnerability if documented; issue only if UI/router/user assumptions treat prior transfer as sender-bound

### Candidate 4: MetaZapNG historical balance contamination

Status:
- Characterized behavior.

Risk:
- pre-existing zap balances can be transferred to current receiver under full-balance flush pattern

Evidence:
- `MetaZapDustHarness` shows full-balance flush transfers pre-existing token balance to the current receiver.
- This is a characterization of the balance-flush pattern, not proof of exploitable behavior in all MetaZapNG paths.

Likely severity:
- depends on actual MetaZapNG paths and whether leftovers can be created, trapped, or extracted unexpectedly

## 5. Tests Written

The suite combines local characterization harnesses with selected real StableSwap NG integration tests.

- `test_stableswap_math.py`
- `test_admin_fee_accounting.py`
- `test_stored_rates_asset_types.py`
- `test_rebasing_balance_semantics.py`
- `test_exchange_received_characterization.py`
- `test_quote_execution_differential.py`
- `test_metazap_dust_characterization.py`
- `test_real_ng_integration.py`

Current local result:
- `uv run pytest tests -q`
- `48 passed`

## 6. Final Assessment

No confirmed exploitable vulnerability was identified in this review pass.

The strongest review conclusion is that StableSwap NG’s core invariant math remains legacy-like, while the main economic risk moves into semantic boundaries:

- asset type correctness
- rate-provider correctness
- ERC4626 conversion behavior
- rebasing balance drift
- quote/execution freshness
- optimistic-transfer settlement
- zap temporary custody

The proportional exit path remains the key safety backstop to keep validating under adverse accounting states.

## 7. Follow-Up Work

- Add factory negative tests for array length, duplicate coins, invalid decimals, invalid implementation index, and fee bounds.
- Add deeper MetaZapNG integration tests against real nested pool paths.
- Add one real metapool underlying quote vs nested execution test.
- Add a real NG test covering `get_dx` / reverse-quote approximation under dynamic fee paths.
- Convert selected tests into public review-note examples.
