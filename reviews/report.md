---
pdf_options:
  headerTemplate: |
    <div style="font-size:10px; text-align:center; width:100%; color:#666;">
      Audit Report | Auditor: YourID
    </div>
  footerTemplate: |
    <div style="font-size:10px; text-align:center; width:100%; color:#666;">
      Page <span class="pageNumber"></span> / <span class="totalPages"></span>
    </div>
  displayHeaderFooter: true
  margin:
    top: 30mm
    bottom: 20mm
---

# Security Audit Report

## Project Information
**Project Name:** [Project Name]
**Protocol Type:** [Lending / AMM / Staking / Cross-Chain / Others]
**Audit Version:** v1.0
**Audit Date:** 2026-XX-XX
**Blockchain:** [Ethereum / BSC / Arbitrum / Optimism / Others]
**Auditor:** [YourID]

## Scope
- Smart Contracts:
  - `ContractA.sol`
  - `ContractB.sol`
  - `ContractC.sol`
- Commit Hash: `0xXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX`
- GitHub Repository: `https://github.com/xxx/xxx`

## Methodology
1. Manual code review
2. Static analysis
3. Dynamic testing & POC verification
4. Economic model & logic review
5. Access control & permission check

## Executive Summary
- Total Issues Found: **X**
  - Critical: 0
  - High: X
  - Medium: X
  - Low: X
  - Informational: X
- Overall Risk Level: [Low / Medium / High]
- Recommendation: [Deploy after fixes / Need further audit / Safe to deploy]

## Issues Found

### [C/H/M/L/I] 1. Issue Title
- **Severity:** [Critical / High / Medium / Low / Informational]
- **Contract:** `ContractName.sol`
- **Location:** Line #XX
- **Description:**
  Describe the vulnerability clearly.
- **Impact:**
  What can attackers do? How much loss?
- **Proof of Concept (POC):**
  ```solidity
  // POC code here
- Recommendation:
How to fix it.

### [C/H/M/L/I] 2. Issue Title
- Severity: [Critical / High / Medium / Low / Informational]
- Contract: ContractName.sol
- Location: Line #XX
- Description:
...
- Impact:
...
- POC:
  ```solidity
  // POC code here
- Recommendation:
...
Best Practices & Improvements
1. Use latest Solidity version (0.8.20+)
2. Add reentrancy guard for external calls
3. Use safe math & safe ERC20 transfer
4. Add event logs for critical operations
5. Implement access control properly
Conclusion
The protocol is [safe / mostly safe / risky] after fixing the above issues.
All critical and high-risk vulnerabilities have been addressed.
The project is recommended to deploy after completing all fixes.

---
Auditor Information
Name: XU, Chen
Twitter/X: @deepthroat_ct
GitHub: https://github.com/chenxu0602
Email: chen.xu.wq@gmail.com
Report Link: https://github.com/$$YourID$$/DeFi-Audit-Reports/$$Project-Name$$/Audit-Report.pdf
