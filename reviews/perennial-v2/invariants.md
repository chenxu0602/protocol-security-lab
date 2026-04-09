# Invariants

Some invariants are document-level anchors and may require multiple test families rather than a single direct assertion.

## Core Accounting Invariants

### 1. Socialized ordinary value must use the intended basis
- Ordinary price PnL must realize on the intended socialized long/short basis, not raw directional size.
- Funding must be computed from the intended socialized taker-notional basis and then realized locally without basis drift.
- Interest must realize on the intended utilized-notional basis.

### 2. Guaranteed-exempt order count must not pay ordinary settlement fee
- For any settled interval, realized ordinary settlement fee must depend only on:
  - `order.orders - guarantee.orders`

### 3. Guaranteed-exempt taker quantity must not pay ordinary taker fee
- For any settled interval, realized ordinary taker trade fee must depend only on:
  - `order.takerTotal() - guarantee.takerFee`

### 4. Guaranteed price override must match signed guaranteed quantity
- Guaranteed price override must equal:
  - `signed guaranteed taker size × (oracle settlement price - guaranteed price)`
- This must remain true after aggregation, rollover, or invalidation paths.

### 5. Protected-order fee must be realized exactly once on the intended path
- Liquidation/protection fee must be a discrete protected-order charge.
- It must:
  - appear only on intended protected-order paths
  - be realized at most once per intended protected-order event

### 6. Per-order fee accumulators must preserve count semantics across aggregation
- Settlement-fee and liquidation/protection-fee paths must preserve their intended count semantics across aggregation.
- In testing, these should be validated as separate fee families.

### 7. Base fee accumulators must reconcile exactly from global write to local realization
- `makerFee` and `takerFee` accumulator writes in `VersionLib` must match local realized base trade-fee amounts in `CheckpointLib`, excluding offset paths.

### 8. Full realized settlement result must be decomposable without unattributed residual
- For a fixed interval and fixed order set, a user's realized collateral delta must be exactly decomposable into:
  - value realization
  - guarantee price override
  - explicit trade fees
  - offsets
  - settlement fee
  - liquidation/protection fee
- No unexplained residual should remain.
