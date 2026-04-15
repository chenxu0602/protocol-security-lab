# Uniswap Foundry Audit Harness

This is a Foundry wrapper around the locally vendored Uniswap v3 repositories in
`../uniswap/v3-core` and `../uniswap/v3-periphery`.

The local dependency links are:

```text
lib/uniswap-v3-core -> ../../uniswap/v3-core
lib/uniswap-v3-periphery -> ../../uniswap/v3-periphery
```

Use this project for audit-focused Foundry tests without modifying the upstream
repository layouts.

Common imports:

```solidity
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
```
