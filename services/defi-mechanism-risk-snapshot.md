# DeFi Mechanism Risk Snapshot

A focused pre-audit review for DeFi teams building lending, vault, LP, perp, or oracle-dependent protocols.

Most serious DeFi failures are not just Solidity bugs. They often come from broken financial assumptions: stale oracle paths, liquidation edge cases, incorrect vault accounting, LP valuation errors, reward accrual drift, and cross-protocol integration mismatch.

The DeFi Mechanism Risk Snapshot is a 3–5 day AI-assisted review designed to surface these risks before a formal audit.

## Focus Areas

- Oracle and price-source behavior
- Liquidation and bad-debt paths
- Vault/share accounting
- LP valuation and Uniswap V3 range logic
- Reward and fee accrual
- Margin and solvency checks
- External protocol adapters

## Deliverables

- Mechanism map
- Risk surface matrix
- Top 5 risk hypotheses
- One runnable PoC or simulation where feasible
- Actionable mitigation checklist
- Short review call

## What This Is Not

This is not a full smart contract audit, formal certification, or guarantee of security. It is a focused mechanism-level review intended to help teams identify high-risk financial logic issues early and prepare for a deeper audit.

## Best For

- Early-stage DeFi protocols before audit
- LP vaults and strategy protocols
- Lending and margin systems
- Perp/options-like protocols
- Teams preparing for Code4rena, Sherlock, Cantina, or private audit