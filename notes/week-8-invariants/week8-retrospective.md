# Week 8 Retrospective

## Goal

Week 8 was not a new protocol review week.  
It was a methodology week focused on:

- invariant thinking
- handler design
- fuzz / stateful testing discipline
- distinguishing characterization, postcondition, and true invariant

The three protocol samples were:

- **Morpho Blue** for hard invariants and handler-based state transitions
- **Yearn V3 (TokenizedStrategy)** for characterization vs invariant
- **Perennial V2** for decomposition and reconciliation testing

---

## Morpho

- handler-based invariant harness can be built from a bounded lending state machine
- some useful protocol properties are easier to encode as liquidation precondition invariants than as full health-function invariants
- sanity checks should not be confused with true invariants
- a small fixed actor set is enough to generate meaningful lending states
- starting with a narrow action set made the harness debuggable and productive
- first useful invariants do not need to be mathematically ambitious; they need to be durable and interpretable

What worked:
- bounded actions: `supply`, `supplyCollateral`, `borrow`, `repay`, `liquidate`, `warp`
- fixed actors instead of arbitrary addresses
- simple liquidation tracking fields
- first-pass market-level ordering bound
- liquidation precondition invariants:
  - successful liquidation requires existing debt
  - successful liquidation requires existing collateral

Main lesson:
For lending systems, useful first invariants often come from **protocol boundary conditions** rather than from trying to fully replicate the protocol’s internal health function.

---

## Yearn V3

- Yearn was a better fit for targeted characterization and bounded reconciliation tests than for handler-first invariant testing
- report timing, unlock timing, and late entry can change user-visible outcomes without implying broken accounting
- honest no-op reports provide a good bounded reconciliation anchor
- fuzz and invariant work already done earlier became more useful once reclassified by purpose

What worked:
- direct tests comparing honest, stale, and overvalue report modes
- timing/frequency tests showing how unlock schedule affects incumbents and late entrants
- invariant work on honest no-op report stability
- monotonicity invariant on unlocked shares

Main lesson:
Yearn is a strong example of a protocol where many “interesting” results are really **semantic timing effects**, not necessarily invariant violations or bugs.

Secondary lesson:
The Week 8 value was not in writing many new Yearn tests, but in correctly sorting existing work into:
- characterization
- fuzz comparison
- invariant / bounded reconciliation

---

## Perennial V2

- Perennial was best approached through targeted reconciliation and decomposition tests rather than through a broad handler
- the most useful tests were the ones that explained user-visible collateral deltas in terms of known settlement components
- fee-domain separation and decomposition remain the cleanest way to reason about dense settlement logic

What worked:
- plain taker checkpoint reconciliation to local collateral delta
- guaranteed intent decomposition into:
  - price override
  - ordinary trade fee
  - claimables
- reuse of earlier `FullDecomposition.t.sol` instead of introducing unnecessary new harness complexity

Main lesson:
For semantically dense settlement systems, the best first tests are often **precise postcondition / reconciliation tests**, not general invariants.

Secondary lesson:
Not every complex protocol benefits from handler-first testing. Sometimes exact scenario control is much higher signal.

---

## Cross-Protocol Lessons

### 1. Handler-first is not universal
- **Morpho** benefited from handler-first testing
- **Yearn** benefited from targeted direct tests first
- **Perennial** benefited from decomposition-first testing

The right testing style depends on protocol structure.

### 2. The hardest part is often choosing the right test type
The real Week 8 skill was not “writing more tests,” but deciding whether a property should be expressed as:
- characterization
- postcondition / reconciliation
- true invariant
- harness sanity check

### 3. Narrow, interpretable properties are stronger than vague ambitious ones
The most useful tests this week were not the most abstract.  
They were the ones with:
- clear scope
- clear semantics
- clear failure meaning

### 4. Foundry becomes much more powerful once tests are treated as protocol modeling
Week 8 made it clear that Foundry is not just for unit tests.  
Its real power comes from:
- stateful protocol modeling
- bounded action spaces
- invariant design
- targeted reconciliation and scenario encoding

---

## What I Learned About Invariants

- a good invariant is usually narrower than first intuition suggests
- sanity checks are useful, but they are not invariants
- some of the most valuable tests are postconditions, not invariants
- monotonicity is often one of the cleanest invariant classes
- liquidation invariants are easier to start from preconditions than from full solvency replication
- decomposition tests are particularly useful for accounting-heavy and settlement-heavy protocols

---

## What I Learned About Foundry

- handler-based testing is genuinely useful for lending-style state machines
- direct targeted tests remain the best tool for explaining protocol semantics
- invariant speed and usefulness depend heavily on:
  - bounded action sets
  - bounded actors
  - avoiding meaningless state exploration
- the distinction between:
  - unit test
  - fuzz comparison
  - invariant
  - characterization test
  - reconciliation test  
  is crucial for clean review work

---

## Outcome of Week 8

By the end of Week 8, the main result was not one new protocol review.  
The main result was a stronger testing methodology across three protocol styles:

- **Morpho Blue**: hard invariants and bounded handlers
- **Yearn V3**: semantic characterization and bounded reconciliation
- **Perennial V2**: decomposition and fee-domain reconciliation

This makes Week 9 more valuable, because the next protocol review can now be approached with a clearer sense of:
- when to use handlers
- when to use direct scenario tests
- what belongs in invariants
- what should remain characterization