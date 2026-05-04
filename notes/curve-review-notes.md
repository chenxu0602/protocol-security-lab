# Curve StableSwap Review Note

## Scope

This note summarizes a focused research and characterization pass over Curve StableSwap and StableSwap NG.

It is not a full production audit. The goal was to clarify the main accounting and semantic boundaries, then back those observations with small local harness tests and selected real NG integration tests.

This review ended up being less about “is StableSwap math still correct?” and more about “what exactly is the pool claiming each token means before the math ever starts.”

That distinction matters much more in StableSwap NG than in legacy Curve.

Legacy StableSwap is already subtle because LP accounting depends on:
- cached balances
- normalized balances
- invariant math
- fee accounting
- wrapper-rate assumptions
- metapool base-pool assumptions

StableSwap NG keeps the same invariant family, but extends the semantic boundary in several important directions:
- asset types
- rate providers
- ERC4626 conversion
- rebasing-token balance drift
- dynamic fee inputs
- quote/execution freshness
- optimistic-transfer settlement

So the most useful review lens became:

> the main risk is usually not the solver itself, but the economic interpretation of the values fed into it.

## Review map

| Layer | Main question |
|---|---|
| Math kernel | Do `get_D`, `get_y`, and `get_y_D` preserve expected StableSwap behavior? |
| Normalization | Do `stored_rates` and `xp` represent the intended economic value? |
| Token semantics | Are plain, oracle-rate, ERC4626, and rebasing assets classified correctly? |
| Settlement | Do transfers, admin fees, and stored balances reconcile in the same unit system? |
| Integration | Do views, zaps, and routers understand quote freshness and temporary custody semantics? |

## Main takeaway

The strongest conclusion from this review is:

> StableSwap NG is still mostly “legacy StableSwap math,” but the highest-value review surface has shifted from invariant algebra toward accounting semantics and configuration semantics.

That means the most important questions are now things like:
- Is the token classified correctly?
- Is the rate source correctly scaled and directionally correct?
- Does rebasing behavior enter accounting only where intended?
- Does quote logic observe the same rate state as execution?
- Are zap leftovers and optimistic-transfer surpluses understood as semantics rather than accidentally treated as sender-bound inputs?

## What became clearer

### 1. The StableSwap math kernel is not where most new risk lives

The review and tests both support that:
- `get_D`
- `get_y`
- `get_y_D`

still behave like the classic StableSwap kernel.

That does not make the system “safe by default.” It just means the main review burden has moved outward.

The real question is whether:

`balances -> stored_rates -> xp`

still describes the intended economic object.

### 2. Asset type is the central NG trust boundary

This was the most important conceptual upgrade in the review.

In legacy Curve, one often asks:
- are cached balances right?
- are wrapper rates stale?
- is metapool base virtual price safe?

In NG, the sharper question is:
- did the pool choose the right economic interpretation for each token?

That matters because a pool can remain internally self-consistent while still being economically wrong if:
- a rebasing token is treated as plain
- an ERC4626 share token is treated as raw ERC20
- an oracle rate is mis-scaled
- a rate points in the wrong economic direction

So “asset type correctness” is not a side detail. It is one of the main review surfaces.

### 3. `exchange_received` is a semantic boundary, not normal sender accounting

One of the most useful pieces of the review was making `exchange_received` concrete.

The right mental model is not:

> the pool knows who transferred the token in

It is:

> the pool consumes whatever optimistic balance delta exists between actual balance and stored balance

That leads to three important consequences:
- in non-rebasing configurations, prior surplus can be consumed by the current caller
- that behavior is not automatically a vulnerability if it is documented and integrations do not assume sender-bound attribution
- in rebasing configurations, this path must be disabled, because balance drift can otherwise impersonate fresh input

This was one of the cleanest examples in the review of a behavior that is important, security-relevant, but not automatically a reportable bug.

### 4. Quote/execution consistency is strong under unchanged state, but freshness is part of the model

Another useful clarification was that Curve NG views are not “bad” in a generic sense.

Under unchanged state:
- direct quote and execution matched in the reviewed plain/oracle paths

But after state changes such as:
- oracle rate updates
- ERC4626 donation-driven share-price changes

previous quotes become stale.

That sounds obvious, but the review helped pin down the sharper version:
- stale quotes are an integration risk
- stale-quote direction is not universally one-sided
- the direction depends on which side of the trade carries the changing rate semantics

That is a more accurate statement than simply saying “quotes can be wrong.”

### 5. Rebasing accounting is intentionally not plain accounting

This review also sharpened the distinction between:
- plain pool semantics
- rebasing-aware semantics

For plain-style accounting:
- cached `stored_balances` remain the accounting base
- direct surplus does not automatically enter ordinary LP accounting

For rebasing-aware accounting:
- actual `balanceOf(pool)` is intentionally reintroduced at selected sync points
- transfer-out logic and proportional-exit logic must respect live balance drift

That difference is not cosmetic. It changes how one should think about:
- surplus
- exitability
- admin fee separation
- `exchange_received`
- proportional remove-liquidity safety

### 6. Admin fee accounting is a unit-conversion problem, not just a fee-rate problem

A small but important review insight was that admin fees are easy to misread if one forgets that fee computation crosses two spaces:
- normalized `xp` space
- raw token-unit space

The main check is not just “is the percentage right?”

It is:

> was the fee computed in normalized value-space converted back into the correct raw token units before being recorded in `admin_balances`?

This matters more once rates differ materially across assets.

### 7. MetaZap-style custody should usually be characterized before it is accused

The MetaZap-style balance-flush pattern is a good example of a surface that can look alarming too quickly.

A zap that reads `balanceOf(self)` and forwards a full leftover amount may:
- transfer pre-existing dust to the current receiver
- contaminate current-caller outcome with historical balances

That is definitely worth review attention.

But the right first step is usually characterization:
- can leftovers arise?
- can they be trapped?
- can they be reassigned across callers?
- is the observed behavior intended adapter semantics or unexpected value transfer?

That review discipline helps avoid turning every leftover-balance pattern into an overclaimed finding.

## What this review did not prove

This was a focused research and characterization pass, not a full audit.

It did not prove:
- full factory safety under all governance and deployment configurations
- full metapool and MetaZapNG path safety
- exhaustive legacy pool-family coverage
- full production deployment safety
- full gauge / reward safety

What it did do was narrow the most important Curve-specific accounting boundaries into a set of much sharper statements and tests.

## Practical lesson

The biggest lesson from this review is that for modern AMMs, “math review” is often not enough.

For StableSwap NG especially, you have to review at least three layers:
- invariant math
- normalization and balance semantics
- deployment/configuration semantics

If the third layer is wrong, the first layer can still look perfectly coherent.

That is why the main surviving risk surfaces here are things like:
- asset-type correctness
- oracle precision/direction
- ERC4626 share-price assumptions
- rebasing drift boundaries
- quote freshness
- optimistic-transfer semantics

not only `D` and `y` algebra.

## Current result

This review pass did not confirm an exploitable vulnerability.

Local result:
- `uv run pytest tests -q`
- `48 passed`

The more useful output was:
- a clearer threat model split between legacy Curve and StableSwap NG
- function notes and invariants grounded in accounting semantics
- a local test suite that now covers:
  - math
  - dynamic fee
  - stored-rate semantics
  - rebasing-vs-plain accounting
  - `exchange_received`
  - admin-fee raw-unit conversion
  - quote/execution differential behavior
  - selected real NG integration paths

So the main progress here is not “everything is safe.”

It is:

> the weak review stories were narrowed, the real semantic boundaries were made explicit, and the remaining higher-value risk surfaces are now much better isolated.
