# Threat Model

## Protocol Summary
Solmate ERC4626 is a tokenized vault implementation where users deposit an underlying asset and receive shares, or redeem/burn shares to receive assets.

## Main Actors / Roles
- Depositor
- Shareholder
- Redeemer / Withdrawer
- External donor to the vault
- Underlying asset contract

## Trust Assumptions
- `totalAssets()` correctly represents the vault's claimable underlying assets
- The underlying asset behaves like a standard ERC20
- Asset transfers succeed as expected
- No hidden asset loss occurs outside modeled behavior

## Privileged Roles
None in the base ERC4626 implementation itself

## External Dependencies
- Underlying ERC20 token behavior
- Safe transfer semantics
- `totalAssets()` implementation in derived vault

## Fund Flows
- Assets enter through `deposit()` or `mint()`
- Assets leave through `withdraw()` or `redeem()`
- Assets may also enter via direct donation, which changes share price without minting shares

## Core State Transitions
- `deposit(assets)` -> transfer assets in, mint shares out
- `mint(shares)` -> compute required assets, transfer in, mint shares
- `withdraw(assets)` -> compute shares to burn, burn shares, transfer assets out
- `redeem(shares)` -> burn shares, transfer computed assets out

## Core Invariants
- Preview functions should match execution in the same state
- Share/asset conversion should remain internally consistent
- Donations should affect price per share without minting new shares
- Entry and exit paths should respect intended rounding direction

## Potential Attack Surfaces
- Rounding asymmetry
- First depositor / low-liquidity edge cases
- Donation / inflation effects
- Preview vs execution mismatch
- Non-standard underlying asset behavior