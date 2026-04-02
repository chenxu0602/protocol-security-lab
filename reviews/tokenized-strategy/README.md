# Yearn V3 Tokenized Strategy — Week 5 Review

## Goal

This review focuses on **vault accounting, share logic, state transitions, and invariant-driven testing** in the Yearn V3 Tokenized Strategy codebase.

The goal is **not** to perform a full audit of the entire repository.  
Instead, this is a scoped review centered on the following question:

> Can share/accounting outcomes become economically unfair, inconsistent, or surprising across deposit, redeem, report, loss, fee, and profit-unlock sequences?

This review is part of my protocol security training, with a long-term focus on:

- EVM financial protocol logic
- accounting and state-transition review
- fuzz / invariant engineering
- vault / rewards / perps / admin-control / trust-model issues

## Review Scope

Primary focus:

- `src/TokenizedStrategy.sol`
- accounting-relevant parts of `src/BaseStrategy.sol`
- related interfaces only as needed to understand trust boundaries and callback assumptions

Main topics in scope:

- deposit / mint accounting
- withdraw / redeem accounting
- share issuance fairness
- multi-user sequencing effects
- `report()`-driven profit/loss realization
- fee assessment
- profit locking / profit unlock behavior
- preview vs execution consistency
- loss handling and `maxLoss` behavior
- accounting assumptions around strategy callbacks such as `_harvestAndReport()` and `_freeFunds()`

Out of scope for this review unless directly relevant to accounting correctness:

- deployment / release mechanics
- generalized governance analysis
- peripheral UX concerns
- non-accounting optimizations
- broad ecosystem integration assumptions

## Review Method

This review is being done as a **manual, accounting-focused protocol review** supported by custom Foundry tests.

Workflow:

1. read specification and architecture
2. define a threat model
3. write function notes for accounting-critical paths
4. define economic and state-machine invariants
5. write focused custom review tests
6. refine issue candidates and final conclusions

This is a learning-oriented review note, **not an official audit report**.

## Core Review Questions

Main questions for this review:

- What is the protocol’s true accounting anchor?
- How do deposits and withdrawals affect fairness across users?
- How are profit, loss, and fees realized into share/accounting state?
- Does profit locking/unlocking create any economically surprising behavior?
- Are `preview*` functions aligned with actual execution in expected ways?
- Are there state sequences where value transfer becomes unintuitive or unfair?
- Are losses handled consistently during exit paths?

## Initial Review Hypotheses

Initial hypotheses to test:

- ordinary no-op round trips should only lose bounded value due to rounding
- profit reports should not let late depositors buy in at an unfairly cheap level
- loss realization during exits may create meaningful edge cases around `maxLoss`
- fee assessment may dilute users in subtle but intended or unintended ways
- profit unlock over time should move claims/PPS in the expected direction
- preview values may diverge from execution after state changes, but the divergence should be explainable rather than arbitrary

## First Tests to Write

The first review tests are chosen to maximize learning about accounting behavior and economic state transitions.

### 1. No-op round trip

Scenario:

- user deposits
- no report
- no loss
- no fee
- same user redeems

Purpose:

- establish a baseline accounting sanity check
- verify that a round trip in a stable state does not create or destroy material value
- confirm that only bounded rounding loss is present

Main assertion:

- the user should recover approximately the original value, with only known/acceptable rounding loss

---

### 2. Profit report then late depositor

Scenario:

- user A deposits
- strategy reports profit
- user B deposits after profit is reported

Purpose:

- test whether late entrants buy into shares at the economically expected level
- study whether profit realization or locking creates unfair entry pricing
- check whether value is unintentionally transferred between early and late users

Main questions:

- does B receive fewer shares than before profit as expected?
- is the amount economically consistent with the design?

---

### 3. Loss realization on withdraw

Scenario:

- user A deposits
- simulate a shortfall through `_freeFunds()`
- compare withdraw/redeem behavior under loss conditions
- inspect `maxLoss` handling

Purpose:

- understand how realized loss affects exit accounting
- verify that withdrawal semantics remain coherent under shortfall
- identify whether withdraw and redeem paths differ in important ways

Main questions:

- when does the operation revert vs succeed?
- how does `maxLoss` shape outcomes?
- can users receive less than expected in surprising ways?

---

### 4. Fee assessment on report

Scenario:

- user deposits
- strategy reports profit
- inspect fee-related accounting updates

Purpose:

- understand how fees are realized into vault/share state
- check whether fee shares or fee value move in the intended direction
- study user dilution from fee realization

Main questions:

- who is diluted and when?
- is fee impact explainable and consistent with the design?
- are fees assessed only when they should be?

---

### 5. Profit unlock over time

Scenario:

- strategy reports profit
- advance time
- inspect accounting/PPS behavior during unlock progression

Purpose:

- understand the effect of locked profit on share/accounting state
- verify that unlock progression changes claims in the intended direction
- test whether time-based profit realization produces surprising outcomes

Main questions:

- does PPS/claim evolution move in the expected direction over time?
- do user outcomes differ materially depending on when they enter/exit during unlock?

---

### 6. Preview vs execution across changed state

Scenario:

- compute preview before report
- report profit or loss
- execute after state change
- compare preview result with actual execution outcome

Purpose:

- test when preview/execution divergence is expected versus suspicious
- understand how state changes affect user-facing pricing expectations
- document where mismatch is legitimate because the state changed

Main questions:

- is the mismatch explainable by report/loss/fee/time state transition?
- does the behavior remain consistent with protocol design?

## Deliverables

This review folder contains:

- `README.md`
- `threat-model.md`
- `function-notes.md`
- `invariants.md`
- `issue-candidates.md`
- `final-review.md`

And supporting custom Foundry tests for the review.

## Intended Outcome for Week 5

A successful Week 5 review does not require finding a dramatic exploit.

It is successful if I can clearly explain:

- the accounting anchor of the system
- how value moves across users over time
- how profit/loss/fees affect share accounting
- what invariants best capture economic correctness
- which behaviors are expected, surprising, fragile, or risky
