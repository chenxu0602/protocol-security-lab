# C&C Ledger Integrity Lab

Security research for financial smart contracts.

Independent smart contract security research focused on protocol risk, financial correctness, and complex DeFi systems such as vaults, AMMs, options, staking, and upgrade-sensitive protocols.

---

## Overview

This repository documents my ongoing work in DeFi security research, review practice, and audit methodology.

My background combines:
- quantitative research and financial markets
- software engineering
- smart contract security
- protocol-level reasoning around accounting, incentives, and edge cases

The goal of this repository is to build a public body of work around reviewing financial smart contracts with an emphasis on:
- protocol risk
- financial correctness
- accounting integrity
- privileged-role and governance risk
- upgrade and deployment risk

---

## Review Focus

I am particularly interested in reviewing:

- **Vaults and accounting-heavy systems**  
  Share issuance, redemptions, fee accrual, reward distribution, unlock logic, and asset-flow consistency.

- **AMMs and liquidity systems**  
  Pricing logic, invariants, manipulation surfaces, liquidity risks, and edge-case state transitions.

- **Options and derivatives protocols**  
  Exercise flows, collateral logic, settlement paths, liquidation assumptions, and risk-sensitive contract design.

- **Staking and reward systems**  
  Reward accounting, emissions logic, claim flows, privileged controls, and insolvency or griefing scenarios.

- **Upgrade-sensitive protocols**  
  Diff review, initialization risk, privilege changes, broken assumptions across versions, and deployment readiness.

---

## Repository Structure

### `evm-playground`
Hands-on practice, proof-of-concept work, and security experiments in the EVM environment.

### `reviews`
Practice reviews, structured notes, and longer-form writeups on protocols or contract systems.

### `templates`
Reusable templates for threat models, findings, review notes, and audit-style deliverables.

### `notes`
Security research notes, protocol design observations, bug patterns, and lessons learned from review practice.

---

## Methodology

My review process typically focuses on:

1. **System understanding**  
   Understanding the protocol’s intended behavior, trust assumptions, and core value flows.

2. **Asset-flow and accounting review**  
   Checking whether balances, shares, rewards, fees, and state transitions remain internally consistent.

3. **Privileged-role analysis**  
   Identifying admin powers, governance risk, emergency controls, and upgrade authority.

4. **Adversarial walkthroughs**  
   Exploring edge cases, abuse paths, griefing vectors, and broken assumptions under stress.

5. **Findings and remediation notes**  
   Writing practical, concise, and implementation-aware review output.

---

## Current Contents

This repository is a working research lab rather than a finished audit portfolio.

Over time, it will include:
- public review notes
- protocol case studies
- sample findings
- audit-style reports
- methodology templates
- invariant and accounting checklists

---

## Selected Themes

Some of the main themes I plan to build out here include:

- ERC4626 and vault accounting risks
- reward distribution and staking failure modes
- AMM invariant and manipulation risk
- financial correctness in derivatives protocols
- upgrade and diff review workflows
- protocol risk assessment for complex DeFi systems

---

## Contact

- GitHub: [chenxu0602](https://github.com/chenxu0602)
- X: [@deepthroat_ct](https://x.com/deepthroat_ct)
- Email: chen.xu.wq@gmail.com
- Location: Hong Kong

---

## Note

This repository contains independent research, practice reviews, and evolving methodology.
It should not be interpreted as a substitute for a full formal audit unless explicitly stated for a specific review.