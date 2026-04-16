# Aave Foundry Audit Harness

This is a Foundry wrapper around the locally vendored Aave V3 repositories in
`../aave`.

The local dependency links are:

```text
lib/forge-std -> ../uniswap-foundry/lib/forge-std
lib/aave-v3-core -> ../../aave/aave-v3-core
lib/aave-v3-periphery -> ../../aave/aave-v3-periphery
```

Use this project for audit-focused Foundry tests without modifying the upstream
repository layouts.

Common imports:

```solidity
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {RewardsController} from "@aave/periphery-v3/contracts/rewards/RewardsController.sol";
```

This wrapper is intended for review-oriented tests around:
- reserve accounting
- solvency and liquidation flows
- flash loan and fee logic
- rewards distribution and claim authorization
- oracle and periphery adapter integration
