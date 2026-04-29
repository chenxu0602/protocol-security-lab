# Balancer Foundry Audit Harness

This is a Foundry wrapper around the locally vendored Balancer V2 monorepo in
`../balancer`.

The local dependency links are:

```text
lib/forge-std -> ../../lib/forge-std
lib/balancer-v2-monorepo -> ../../balancer/balancer-v2-monorepo
```

Use this project for audit-focused Foundry tests without modifying the upstream
repository layout.

The wrapper remappings are set up so Balancer monorepo package imports work
directly, including:
- `@balancer-labs/v2-interfaces`
- `@balancer-labs/v2-vault`
- `@balancer-labs/v2-pool-weighted`
- `@balancer-labs/v2-solidity-utils`
- `@balancer-labs/v2-pool-utils`
- `@balancer-labs/v2-pool-stable`

Example imports:

```solidity
import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-vault/contracts/Vault.sol";
import "@balancer-labs/v2-pool-weighted/contracts/WeightedPool.sol";
```

Place audit tests under `test/`.
