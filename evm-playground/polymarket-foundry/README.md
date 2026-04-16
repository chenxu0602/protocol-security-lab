# Polymarket Foundry Audit Harness

This is a Foundry wrapper around the locally vendored Polymarket repositories in
`../polymarket`.

The local dependency links are:

```text
lib/forge-std -> ../uniswap-foundry/lib/forge-std
lib/polymarket -> ../../polymarket
```

Use this project for audit-focused Foundry tests without modifying the upstream
repository layouts.

Current remappings are set up to make the most common Polymarket modules easy to
import from this wrapper:
- `ctf-exchange`
- `ctf-exchange-v2`
- `exchange-fee-module`

Some Polymarket modules, especially `neg-risk-ctf-adapter`, use project-local
absolute imports like `src/...` and may need target-specific remappings added
when you focus on that module.

Also note that some upstream Polymarket subprojects currently have empty local
`lib/` directories in this workspace. The wrapper itself builds, but compiling
full upstream contracts may still require pulling those upstream dependencies
first.

Example imports:

```solidity
import {CTFExchange} from "polymarket/ctf-exchange/src/exchange/CTFExchange.sol";
import {FeeModule} from "polymarket/exchange-fee-module/src/FeeModule.sol";
import {CTFExchange as CTFExchangeV2} from "polymarket/ctf-exchange-v2/src/exchange/CTFExchange.sol";
```
