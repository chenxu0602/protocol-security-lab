# Review Note: Reward Accounting Was Not the Main Risk

This is a learning-oriented review note based on a public staking rewards implementation.  
It is **not** an official audit engagement, and the goal here is to capture security lessons from reviewing a real codebase.

## Main takeaway

The most interesting part of this review was **not** a classic exploit like reentrancy or arithmetic overflow.

The stronger conclusion was that:

> **user reward claims depend heavily on owner behavior, not only on internal reward accounting correctness.**

In other words, the contract can keep reward accounting internally consistent while users still lack strong protection over the actual economic value of their reward claims.

## What the contract does

At a high level, the contract:

- accepts a staking token
- mints an ERC20 balance representing staked principal
- accrues rewards over time using a global reward index
- lets users later withdraw principal and claim reward tokens

It also includes strong owner-controlled features such as:

- whitelist management
- pause / unpause
- reward funding
- reward APY configuration
- reward release timing
- reward-token reclaim
- ERC20 recovery
- oracle-based rebalance behavior

So the contract is not just a simple staking pool. It also encodes a fairly strong operational and administrative trust model.

## What looked solid

A few things were conceptually reasonable:

- reward accounting follows a recognizable global-index plus per-user-checkpoint pattern
- reward state is updated before balance changes on key paths
- the contract has meaningful test coverage for lifecycle and admin behavior
- withdrawals are intentionally allowed even if rebalance fails, which may help principal recoverability under oracle issues

These are all useful properties.

## The more important risks

The stronger review findings were not “random attacker can drain funds.”

Instead, they were mostly about **admin power, reserve backing, and user claim realization**.

### 1. Whitelist removal can block users from accessing their own position

In this implementation, whitelist checks are applied not only to entry, but also to:

- `withdraw()`
- `getReward()`
- `exit()`

That means a user who already staked can later be removed from the whitelist and become unable to:

- withdraw principal
- claim rewards
- fully exit the system

This is more than an onboarding restriction. It is an ongoing control surface over user funds.

### 2. Reward accounting can remain positive while reward-token backing is removed

The contract includes administrative paths that can remove reward-token reserves even while accounting still shows user reward claims.

Two important examples are:

- `reclaim()`
- `recoverERC20()` when used on the reward token

This creates a mismatch between:

- **accounting-side entitlement**
- **actual token reserves available for payout**

That is an important security lesson:

> **internal reward accounting is not enough if reserve backing can be removed by privileged actors.**

### 3. Owner trust assumptions dominate reward safety

Taken together, the review suggested that the main security question is not only:

> “Is reward math correct?”

but also:

> “Under what owner behaviors do user claims remain meaningfully protected?”

This distinction matters a lot.

A protocol can look mathematically sound while still giving users only **conditional** economic claims.

## Why this matters

When reviewing DeFi systems, it is easy to focus only on:

- reentrancy
- precision bugs
- overflow / underflow
- missing access control

Those are important, but they are not the whole story.

Sometimes the more important risk is:

- users believe they have a claim
- the contract’s accounting agrees they have a claim
- but privileged actions can still make that claim practically unrealizable

That is a real security property, even if it is not a permissionless exploit.

## My review angle

For this review, the most useful questions were:

- Can already-accrued rewards be made unclaimable?
- Can principal be trapped by operational/admin controls?
- Can reward-token reserves be removed while user claims remain in accounting?
- Are user claims protected by contract logic, or mainly by owner restraint?

Those questions ended up being more interesting than “is there a classic bug?”

## Practical lesson

A good review should distinguish between:

- **code exploit risk**
- **design risk**
- **trust-model risk**
- **reserve-backing risk**
- **user-funds access risk**

Not every important finding is a conventional exploit.

Some of the most meaningful findings are really about:

- who can change the rules,
- who can remove backing,
- and whether user claims are actually enforceable under adverse admin behavior.

## Closing thought

The biggest lesson from this review was:

> **reward accounting correctness and user reward safety are not the same thing.**

A protocol may track rewards correctly on paper while still giving privileged actors multiple ways to neutralize, defer, or block the economic realization of those rewards.

That is exactly the kind of distinction I want to keep getting better at identifying in future reviews.