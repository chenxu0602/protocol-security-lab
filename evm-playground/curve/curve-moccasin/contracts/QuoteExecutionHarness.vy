# pragma version ^0.4.0

interface RateOracle:
    def get_rate() -> uint256: view


interface ERC4626:
    def convertToAssets(shares: uint256) -> uint256: view


N_COINS: constant(uint256) = 2
PRECISION: constant(uint256) = 10**18
A_PRECISION: constant(uint256) = 100
FEE_DENOMINATOR: constant(uint256) = 10**10
ASSET_TYPE_PLAIN: constant(uint256) = 0
ASSET_TYPE_ORACLE: constant(uint256) = 1
ASSET_TYPE_ERC4626: constant(uint256) = 3

balances: public(uint256[N_COINS])
rate_multipliers: public(uint256[N_COINS])
asset_types: public(uint256[N_COINS])
rate_oracles: public(address[N_COINS])
call_amount: public(uint256[N_COINS])
scale_factor: public(uint256[N_COINS])
amp: public(uint256)
fee: public(uint256)
offpeg_fee_multiplier: public(uint256)


@deploy
def __init__(
    balances_: uint256[N_COINS],
    rate_multipliers_: uint256[N_COINS],
    asset_types_: uint256[N_COINS],
    rate_oracles_: address[N_COINS],
    call_amount_: uint256[N_COINS],
    scale_factor_: uint256[N_COINS],
    amp_: uint256,
    fee_: uint256,
    offpeg_fee_multiplier_: uint256,
):
    self.balances = balances_
    self.rate_multipliers = rate_multipliers_
    self.asset_types = asset_types_
    self.rate_oracles = rate_oracles_
    self.call_amount = call_amount_
    self.scale_factor = scale_factor_
    self.amp = amp_
    self.fee = fee_
    self.offpeg_fee_multiplier = offpeg_fee_multiplier_


@external
def set_balances(balances_: uint256[N_COINS]):
    self.balances = balances_


@internal
@view
def _stored_rates() -> uint256[N_COINS]:
    rates: uint256[N_COINS] = self.rate_multipliers

    for i: uint256 in range(N_COINS):
        if self.asset_types[i] == ASSET_TYPE_ORACLE and self.rate_oracles[i] != empty(address):
            fetched_rate: uint256 = staticcall RateOracle(self.rate_oracles[i]).get_rate()
            rates[i] = rates[i] * fetched_rate // PRECISION
        elif self.asset_types[i] == ASSET_TYPE_ERC4626:
            rates[i] = (
                rates[i]
                * staticcall ERC4626(self.rate_oracles[i]).convertToAssets(self.call_amount[i])
                * self.scale_factor[i]
                //
                PRECISION
            )

    return rates


@external
@view
def stored_rates() -> uint256[N_COINS]:
    return self._stored_rates()


@internal
@view
def _xp_mem(_balances: uint256[N_COINS], rates: uint256[N_COINS]) -> uint256[N_COINS]:
    xp: uint256[N_COINS] = empty(uint256[N_COINS])
    for i: uint256 in range(N_COINS):
        xp[i] = _balances[i] * rates[i] // PRECISION
    return xp


@external
@view
def xp() -> uint256[N_COINS]:
    return self._xp_mem(self.balances, self._stored_rates())


@internal
@pure
def _get_D(xp: uint256[N_COINS], amp_: uint256) -> uint256:
    S: uint256 = xp[0] + xp[1]
    if S == 0:
        return 0

    D: uint256 = S
    Ann: uint256 = amp_ * N_COINS

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


@internal
@pure
def _get_y(i: uint256, j: uint256, x: uint256, xp: uint256[N_COINS], amp_: uint256) -> uint256:
    D: uint256 = self._get_D(xp, amp_)
    Ann: uint256 = amp_ * N_COINS

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


@internal
@view
def _dynamic_fee(xpi: uint256, xpj: uint256) -> uint256:
    if self.offpeg_fee_multiplier <= FEE_DENOMINATOR:
        return self.fee

    xps2: uint256 = (xpi + xpj) ** 2
    return (
        self.offpeg_fee_multiplier
        * self.fee
        //
        (
            (self.offpeg_fee_multiplier - FEE_DENOMINATOR) * 4 * xpi * xpj // xps2
            + FEE_DENOMINATOR
        )
    )


@internal
@view
def _get_dy(i: uint256, j: uint256, dx: uint256) -> uint256:
    assert i < N_COINS
    assert j < N_COINS
    assert i != j

    rates: uint256[N_COINS] = self._stored_rates()
    xp: uint256[N_COINS] = self._xp_mem(self.balances, rates)
    dx_scaled: uint256 = dx * rates[i] // PRECISION
    x: uint256 = xp[i] + dx_scaled
    y: uint256 = self._get_y(i, j, x, xp, self.amp)
    dy_scaled: uint256 = xp[j] - y - 1
    fee_rate: uint256 = self._dynamic_fee((xp[i] + x) // 2, (xp[j] + y) // 2)
    dy_scaled -= fee_rate * dy_scaled // FEE_DENOMINATOR
    return dy_scaled * PRECISION // rates[j]


@external
@view
def get_dy(i: uint256, j: uint256, dx: uint256) -> uint256:
    return self._get_dy(i, j, dx)


@external
def exchange(i: uint256, j: uint256, dx: uint256) -> uint256:
    dy: uint256 = self._get_dy(i, j, dx)
    self.balances[i] += dx
    self.balances[j] -= dy
    return dy
