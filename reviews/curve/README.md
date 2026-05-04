# Curve Review Scope

This review uses two related but separate threat models:

- `curve-contract-threat-model.md`
  - legacy Curve StableSwap templates, including Base, Meta, Y, Aave, ETH, Zap, and LP token contracts

- `stableswap-ng-threat-model.md`
  - modern StableSwap NG, focusing on factory deployment, asset types, rate providers, ERC4626, rebasing assets, dynamic fees, views, and metazap routes

The shared accounting model is:

`balances -> xp -> D/y -> LP supply / virtual price`

StableSwap NG adds a much larger deployment-configuration and asset-type correctness surface on top of that shared model.
