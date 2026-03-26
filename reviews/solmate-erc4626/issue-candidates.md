# Issue Candidates

## Candidate 1: Donation-driven price manipulation changes entry fairness
Observation:
Direct asset donation changes conversion outcomes without minting shares.

Potential impact:
Late depositors receive fewer shares per asset than earlier depositors.

Status:
Likely intended ERC4626 behavior, but important accounting/review consideration.

## Candidate 2: Tiny deposits may mint zero shares without explicit guard
Observation:
Because previewDeposit uses downward rounding, very small deposits can map to zero shares after share price increases.

Potential impact:
User donates assets to vault and receives zero shares.

Status:
Mitigated in Solmate by explicit `ZERO_SHARES` check in deposit.

## Candidate 3: Preview/execution mismatch risk if totalAssets is unstable or non-standard
Observation:
Preview correctness depends entirely on totalAssets being reliable at execution time.

Potential impact:
Users may receive materially different results than previewed.

Status:
Depends on derived vault design and underlying asset behavior.

## Candidate 4: Non-standard ERC20 behavior may break accounting assumptions
Observation:
Fee-on-transfer or rebasing assets may invalidate expected relationship between transferred assets and vault accounting.

Potential impact:
Shares may be mispriced or previews may become misleading.

Status:
Out-of-scope for base implementation correctness, but critical integration risk.