# Function Notes

## Conversion Layer

### totalAssets()
- Defined by the derived vault
- Core source of truth for asset-side accounting
- Any inaccuracy here breaks all conversion logic

### convertToShares(uint256 assets)
- Uses current `totalSupply` and `totalAssets`
- Returns 1:1 when supply is zero
- Uses downward rounding

### convertToAssets(uint256 shares)
- Uses current `totalSupply` and `totalAssets`
- Returns 1:1 when supply is zero
- Uses downward rounding

### previewDeposit(uint256 assets)
- Delegates to `convertToShares`
- Used to estimate shares minted for a deposit

### previewMint(uint256 shares)
- Computes assets required to mint a target number of shares
- Uses upward rounding

### previewWithdraw(uint256 assets)
- Computes shares required to withdraw a target number of assets
- Uses upward rounding

### previewRedeem(uint256 shares)
- Delegates to `convertToAssets`
- Estimates assets returned for share redemption

## Entry Layer

### deposit(uint256 assets, address receiver)
- Checks preview result is nonzero
- Transfers assets in first
- Mints shares after assets received
- Important for donation and accounting reasoning

### mint(uint256 shares, address receiver)
- Computes required assets using upward rounding
- Transfers assets in
- Mints requested shares

## Exit Layer

### withdraw(uint256 assets, address receiver, address owner)
- Computes shares to burn using upward rounding
- Handles allowance if caller != owner
- Burns shares before transferring assets
- Important for consistency between preview and execution

### redeem(uint256 shares, address receiver, address owner)
- Checks preview result is nonzero
- Handles allowance if caller != owner
- Burns shares
- Transfers computed assets out