# Panoptic Foundry Audit Harness

This is a Foundry wrapper around the locally vendored Panoptic repositories in
`../panoptic`.

The local dependency links are:

```text
lib/forge-std -> ../../lib/forge-std
lib/panoptic-v2-core -> ../../panoptic/panoptic-v2-core
```

Use this project for audit-focused Foundry tests without modifying the upstream
repository layouts.

The wrapper remappings are set up to make the main Panoptic V2 core modules easy
to import, including:
- `@contracts`
- `@libraries`
- `@base`
- `@types`
- `v4-core`
- `univ3-core`

Example imports:

```solidity
import {PanopticPoolV2} from "panoptic-v2-core/contracts/PanopticPool.sol";
import {RiskEngine} from "panoptic-v2-core/contracts/RiskEngine.sol";
import {Constants} from "panoptic-v2-core/contracts/libraries/Constants.sol";
```

The upstream Panoptic repo is fairly large, so this wrapper is intended as a
review harness rather than a standalone application repo.
