# Monetrix Review Plan

## 1. Contest Constraints

Important C4 constraints:

- High / Medium submissions require runnable coded PoC.
- PoC must be written in `test/c4/C4Submission.t.sol`.
- Exploit must be inside `test_submissionValidity`.
- V12 findings are out of scope.
- Operator compromise / inaction is publicly known / out of scope.
- Single upgrader risk is publicly known / out of scope.
- Non-final parameters are publicly known / out of scope.

Review goal:

Find 1-2 strong Medium candidates with runnable PoC, not many weak QA issues.

---

## 2. Priority Surfaces

### P0: Redemption / yield accounting

Files:

- `MonetrixVault.sol`
- `MonetrixAccountant.sol`
- `RedeemEscrow.sol`
- `YieldEscrow.sol`

Questions:

- Is `shortfall()` enough to protect redemption obligations?
- Can funded redemption obligations support yield settlement?
- Can `settle()` transfer USDC that should remain reserved?
- Does `requestRedeem` burn USDM or keep totalSupply unchanged?
- Does `distributableSurplus()` reflect all liabilities?

Deliverable:

- PoC for redemption obligation vs distributable surplus.

---

### P1: L1 backing valuation

Files:

- `MonetrixAccountant.sol`
- `PrecompileReader.sol`
- `TokenMath.sol`
- `MonetrixConfig.sol`

Questions:

- Does `accountValueSigned` overlap with spot balances?
- Does supplied balance overlap with spot balance?
- Does HLP equity overlap with account value?
- Are signed values handled correctly?
- Are decimals correct?
- Are spot token and pair asset ids used correctly?

Deliverable:

- If a domain overlap is real, PoC showing `totalBackingSigned()` overstates backing and settle succeeds.

---

### P2: sUSDM cooldown / yield distribution

Files:

- `sUSDM.sol`
- `sUSDMEscrow.sol`
- `MonetrixVault.sol`

Questions:

- Does cooldown preserve rate?
- Does escrow balance match pending claims?
- Can repeated cooldown split extract rounding?
- Can near-zero supply capture yield unfairly?
- Does `injectYield` handle caps and zero supply correctly?

Deliverable:

- Probe tests. Submit only if user harm is clear.

---

### P3: Bridge / bank-run behavior

Files:

- `MonetrixVault.sol`
- `RedeemEscrow.sol`
- `MonetrixConfig.sol`

Questions:

- Does `netBridgeable()` reserve enough liquidity?
- Can bridge worsen redemption shortfall?
- Is `outstandingL1Principal` updated consistently?
- Can users be stuck after allowed bridge?

Deliverable:

- PoC showing allowed bridge causes redemption failure due to formula bug.

---

## 3. Work Sequence

### Step 1: Confirm redemption flow

Run:

```bash
grep -n "function requestRedeem" -A60 src/core/MonetrixVault.sol
grep -n "function claimRedeem" -A60 src/core/MonetrixVault.sol
grep -n "function addObligation" -A25 src/core/RedeemEscrow.sol
grep -n "function shortfall" -A25 src/core/RedeemEscrow.sol