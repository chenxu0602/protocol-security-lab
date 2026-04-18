# Issue Candidates

## Confirmed Intended Behavior

### 1. `repayWithATokens()` and underlying `repay()` are economically coherent
**Status:** Confirmed intended behavior

**What was checked:**
- For the same reserve, user, debt mode, and nominal repay amount:
  - debt reduction is approximately equal across the two paths
  - resulting reserve-side and token-side accounting remains coherent

**Observation:**
- The two paths are economically aligned on debt reduction.
- The operational settlement path is different:
  - `repay()` pulls underlying from the repayer into the reserve aToken
  - `repayWithATokens()` burns the payer’s aTokens instead of requiring a fresh underlying transfer
- This is a settlement-path difference, not an immediate economic inconsistency by itself.

**Why it matters:**
- This confirms the intended repay-path equivalence at the debt-accounting level.
- Future concerns should focus on edge cases such as rounding, accrued-interest timing, and max-repay dust behavior, not on basic parity itself.

**Validated in:**
- `RepayParity.t.sol`

---

### 2. Healthy positions are not liquidatable at the HF boundary
**Status:** Confirmed intended behavior

**What was checked:**
- HF just above `1e18` causes liquidation to revert
- HF just below `1e18` allows liquidation to succeed

**Observation:**
- The solvency boundary behaves as intended in the tested setup.
- No obvious off-by-one or immediate threshold inversion was observed around `HF = 1`.

**Why it matters:**
- This reduces concern that the core liquidation gate is trivially broken at the liquidation threshold.
- Remaining risk, if any, is more likely to come from valuation source changes, mode interactions, or rounding under more exotic configurations.

**Validated in:**
- `HealthFactorBoundary.t.sol`

---

### 3. Liquidation settlement is value-coherent in the tested path
**Status:** Confirmed intended behavior

**What was checked:**
- Debt burned matches actual debt reduction
- Collateral seized is coherent with oracle pricing and liquidation bonus
- Protocol fee is carved out from the bonus side
- Total user collateral loss stays within the user’s collateral balance

**Observation:**
- In the tested liquidation path, settlement is internally coherent.
- Borrower loss, liquidator receive amount, and protocol fee reconcile as expected.

**Why it matters:**
- This lowers concern of a straightforward over-seizure / under-burn bug in the tested branch.
- It also confirms that liquidation fee extraction is conceptually bonus-splitting, not arbitrary extra collateral confiscation.

**Validated in:**
- `LiquidationSettlement.t.sol`

---

## Accounting-Sensitive Observations

### 1. Liquidation is cross-reserve settlement, not a single-reserve event
**Why this matters:**
- Liquidation touches:
  - the debt reserve
  - the collateral reserve
  - borrower balance state
  - liquidator settlement
  - treasury fee state
- Correctness is not captured by inspecting only one reserve delta in isolation.
- A bug can exist even if each reserve looks locally reasonable while the cross-reserve economic reconciliation is wrong.

**Review implication:**
- Future investigation should reconcile debt asset spent, debt burned, collateral transferred, protocol fee, and borrower residual state as one combined settlement equation.

---

### 2. Isolation debt accounting is principal-like side-accounting
**Why this matters:**
- Isolation-mode debt accounting is not simply “current live debt token balance with accrued interest.”
- It is maintained through a separate principal-like side-accounting path with its own update semantics.

**Review implication:**
- If an issue exists around isolation mode, it is more likely to appear in borrow / repay / liquidation transitions, rounding, or debt-ceiling enforcement than in ordinary reserve debt token balances alone.

---

### 3. Liquidation protocol fee is taken from bonus collateral, not from base repayment value
**Why this matters:**
- The protocol fee does not mean the protocol takes extra collateral on top of everything else.
- Base collateral corresponds to repaid debt value.
- Liquidation bonus creates the incentive spread.
- Protocol fee is carved out of that bonus spread.

**Review implication:**
- Future assertions should separate:
  - base collateral
  - bonus collateral
  - protocol fee

rather than treating the full seized amount as one homogeneous value bucket.

---

### 4. Repay-path equality should be judged economically, not by identical token-flow shape
**Why this matters:**
- `repay()` and `repayWithATokens()` do not need to produce identical intermediate token movements.
- The right invariant is approximate equality in economic effect:
  - debt reduction
  - reserve/token reconciliation
  - absence of value creation or loss outside expected rounding

**Review implication:**
- “Reserve cash path differs” is an observation, not by itself a bug.
- Candidate issues need to show an actual accounting divergence, not merely a different execution path.

---

## Open Candidate Concerns

Only the points below look worth deeper follow-up.

### 1. Mixed stable-debt / variable-debt liquidation ordering and burn composition
**Why this is still worth digging:**
- Current test coverage is variable-debt-heavy only.
- Aave liquidation can interact with both stable and variable debt balances.
- If there is a latent issue, it may show up in:
  - which debt bucket is burned first
  - whether close-factor application is economically consistent across mixed debt
  - whether post-liquidation user state remains coherent when both debt types exist

**What to probe next:**
- Borrower with both stable and variable debt on the same asset
- Liquidation amount near close-factor boundary
- Per-bucket debt reduction and total settlement coherence

---

### 2. Edge-case rounding when borrower collateral is near full exhaustion
**Why this is still worth digging:**
- Liquidation logic includes:
  - collateral cap by user balance
  - bonus application
  - protocol fee extraction
  - scaled-balance / index effects
- These are classic places where small rounding discrepancies can accumulate into unexpected state transitions.

**What to probe next:**
- Borrower collateral just barely sufficient vs. barely insufficient
- Non-zero liquidation protocol fee
- No over-seizure
- No treasury over-collection
- No inconsistent borrower collateral flag transition

---

### 3. `repayWithATokens(type(uint256).max)` and dust-clearing edge behavior
**Why this is still worth digging:**
- The aToken max-repay path resolves against actual aToken balance to avoid dust.
- That usually means there are branch-specific rounding and balance-resolution behaviors worth stressing.

**What to probe next:**
- Self-repay with accrued interest
- aToken balance slightly below, equal to, and above outstanding debt
- No stranded debt dust
- No unintended over-burn

---

### 4. Isolation-mode side-accounting coherence across repay and liquidation
**Why this is still worth digging:**
- The side-accounting is separate and principal-like.
- Even if reserve debt token balances look correct, isolation debt ceiling state could drift across transitions.

**What to probe next:**
- Isolated-collateral user borrows isolated-eligible asset
- Partial repay
- Partial liquidation
- Verify isolation total debt decreases coherently and does not desynchronize from effective principal exposure

---

### 5. Close-factor regime boundary at `HF = 0.95e18`
**Why this is still worth digging:**
- Current boundary testing covered liquidation eligibility around `HF = 1e18`.
- Aave has another important branch boundary at `HF = 0.95e18`, where close factor changes from 50% to 100%.
- This is a meaningful accounting threshold and a plausible source of branch-sensitive mistakes.

**What to probe next:**
- HF just above `0.95e18`
- HF just below `0.95e18`
- Compare:
  - allowed debt-to-cover
  - actual debt burn
  - collateral seizure consistency