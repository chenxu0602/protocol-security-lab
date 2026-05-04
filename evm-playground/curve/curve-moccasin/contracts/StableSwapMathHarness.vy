# contracts/StableSwapMathHarness.vy

# pragma version ^0.4.0

N_COINS: constant(uint256) = 3
A_PRECISION: constant(uint256) = 100
FEE_DENOMINATOR: constant(uint256) = 10**10

@external
@pure
def sum_xp(xp: uint256[N_COINS]) -> uint256:
    s: uint256 = 0
    for i: uint256 in range(N_COINS):
        s += xp[i]
    return s


@internal
@pure
def _get_D(xp: uint256[N_COINS], amp: uint256) -> uint256:
    S: uint256 = 0
    for i: uint256 in range(N_COINS):
        S += xp[i]

    if S == 0:
        return 0

    D: uint256 = S
    Ann: uint256 = amp * N_COINS

    for _i: uint256 in range(255):
        D_P: uint256 = D

        for j: uint256 in range(N_COINS):
            D_P = D_P * D // (xp[j] * N_COINS)

        Dprev: uint256 = D

        D = (
            (Ann * S // A_PRECISION + D_P * N_COINS) * D
            //
            ((Ann - A_PRECISION) * D // A_PRECISION + (N_COINS + 1) * D_P)
        )

        if D > Dprev:
            if D - Dprev <= 1:
                return D
        else:
            if Dprev - D <= 1:
                return D

    return D


@external
@pure
def get_D(xp: uint256[N_COINS], amp: uint256) -> uint256:
    return self._get_D(xp, amp)


@external
@pure
def get_y(i: uint256, j: uint256, x: uint256, xp: uint256[N_COINS], amp: uint256) -> uint256:
    assert i != j
    assert i < N_COINS
    assert j < N_COINS

    D: uint256 = self._get_D(xp, amp)
    Ann: uint256 = amp * N_COINS

    c: uint256 = D
    S_: uint256 = 0
    _x: uint256 = 0

    for k: uint256 in range(N_COINS):
        if k == i:
            _x = x
        elif k != j:
            _x = xp[k]
        else:
            continue

        S_ += _x
        c = c * D // (_x * N_COINS)

    c = c * D * A_PRECISION // (Ann * N_COINS)
    b: uint256 = S_ + D * A_PRECISION // Ann

    y: uint256 = D
    y_prev: uint256 = 0

    for _k: uint256 in range(255):
        y_prev = y
        y = (y * y + c) // (2 * y + b - D)

        if y > y_prev:
            if y - y_prev <= 1:
                return y
        else:
            if y_prev - y <= 1:
                return y

    return y


@external
@pure
def get_y_D(i: uint256, xp: uint256[N_COINS], D: uint256, amp: uint256) -> uint256:
    assert i < N_COINS

    Ann: uint256 = amp * N_COINS
    c: uint256 = D
    S_: uint256 = 0
    _x: uint256 = 0

    for k: uint256 in range(N_COINS):
        if k == i:
            continue

        _x = xp[k]
        S_ += _x
        c = c * D // (_x * N_COINS)

    c = c * D * A_PRECISION // (Ann * N_COINS)
    b: uint256 = S_ + D * A_PRECISION // Ann

    y: uint256 = D
    y_prev: uint256 = 0

    for _k: uint256 in range(255):
        y_prev = y
        y = (y * y + c) // (2 * y + b - D)

        if y > y_prev:
            if y - y_prev <= 1:
                return y
        else:
            if y_prev - y <= 1:
                return y

    return y


@external
@pure
def dynamic_fee(
    xpi: uint256,
    xpj: uint256,
    fee: uint256,
    offpeg_fee_multiplier: uint256,
) -> uint256:
    if offpeg_fee_multiplier <= FEE_DENOMINATOR:
        return fee

    xps2: uint256 = (xpi + xpj) ** 2
    return (
        offpeg_fee_multiplier
        * fee
        //
        (
            (offpeg_fee_multiplier - FEE_DENOMINATOR) * 4 * xpi * xpj // xps2
            + FEE_DENOMINATOR
        )
    )
