# C&C Ledger Integrity Lab

Security research for financial smart contracts.

Independent smart contract security research focused on protocol risk, financial correctness, and complex DeFi systems such as vaults, AMMs, options, staking, and upgrade-sensitive protocols.

---

## Overview

This repository is my public workspace for DeFi security research, review practice, and audit-style writing.

My background combines:
- quantitative research and financial markets
- software engineering
- smart contract security
- protocol-level reasoning about incentives, accounting, and edge cases

The goal of this repository is to build a focused body of public work around reviewing financial smart contracts, especially where economic logic, accounting integrity, and privileged controls matter as much as implementation correctness.

---

## Research Focus

I am particularly interested in:

- **Vaults and accounting-heavy systems**  
  Share issuance, redemptions, fee accrual, reward distribution, unlock logic, and asset-flow consistency.

- **AMMs and liquidity systems**  
  Pricing logic, invariants, manipulation surfaces, liquidity risk, and state-transition edge cases.

- **Options and derivatives protocols**  
  Collateral flows, settlement paths, liquidation assumptions, exercise mechanics, and risk-sensitive contract design.

- **Staking and reward systems**  
  Reward accounting, emissions logic, reserve backing, claim flows, and privileged controls.

- **Upgrade-sensitive protocols**  
  Diff review, initialization risk, privilege changes, deployment readiness, and broken assumptions across versions.

---

## What This Repository Contains

### `notes/`
Public research notes, case studies, and review observations on protocol design, bug patterns, and security lessons.

### `reviews/`
Structured review writeups and longer-form audit-style documents.

### `templates/`
Reusable templates for threat models, findings, review memos, and audit-style deliverables.

### `evm-playground/`
Hands-on practice, proof-of-concept work, and security experiments in the EVM environment.

---

## Review Methodology

My review process usually centers on five questions:

1. **What is the system trying to guarantee?**  
   Understand intended behavior, trust assumptions, and core value flows.

2. **Do accounting and state transitions remain internally consistent?**  
   Check balances, shares, rewards, fees, redemptions, and edge-case transitions.

3. **What powers do privileged actors really have?**  
   Analyze governance, admin controls, emergency actions, token recovery, and upgrade authority.

4. **What breaks under adversarial or stressed conditions?**  
   Explore abuse paths, griefing vectors, reserve depletion, blocked exits, and assumption failures.

5. **What is the practical consequence for users and protocol operators?**  
   Translate findings into concrete risk, not just code-level observations.

---

## Selected Themes

This repository is especially focused on:
- ERC4626 and vault accounting risk
- reward distribution and staking failure modes
- AMM invariant and manipulation risk
- financial correctness in derivatives protocols
- upgrade and diff review workflows
- protocol risk assessment for complex DeFi systems

---

## Selected Notes

- [Review Note: Reward Accounting Was Not the Main Risk](./notes/case-study-fixed-staking-rewards.md)  
  A public review note on staking design, reserve backing, privileged controls, and why internally correct reward accounting does not automatically mean user reward safety.

---

## Current Status

This repository is a working research lab rather than a polished commercial portfolio.

It is intended to grow over time into a stronger public record of:
- review notes
- case studies
- sample findings
- audit-style reports
- methodology templates
- accounting and invariant checklists

---

## Contact

- GitHub: [chenxu0602](https://github.com/chenxu0602)
- X: [@deepthroat_ct](https://x.com/deepthroat_ct)
- Email: chen.xu.wq@gmail.com
- Location: Hong Kong

---

## Note

This repository contains independent research, practice reviews, and evolving methodology.

Unless explicitly stated otherwise, the materials here should be treated as public research notes rather than formal commercial audit reports.