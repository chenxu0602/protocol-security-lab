# pragma version ^0.4.0

interface RateOracle:
    def get_rate() -> uint256: view


interface ERC4626:
    def convertToAssets(shares: uint256) -> uint256: view


N_COINS: constant(uint256) = 2
PRECISION: constant(uint256) = 10**18
ASSET_TYPE_PLAIN: constant(uint256) = 0
ASSET_TYPE_ORACLE: constant(uint256) = 1
ASSET_TYPE_REBASING: constant(uint256) = 2
ASSET_TYPE_ERC4626: constant(uint256) = 3

coins: public(address[N_COINS])
asset_types: public(uint256[N_COINS])
rate_multipliers: public(uint256[N_COINS])
rate_oracles: public(address[N_COINS])
call_amount: public(uint256[N_COINS])
scale_factor: public(uint256[N_COINS])


@deploy
def __init__(
    coins_: address[N_COINS],
    asset_types_: uint256[N_COINS],
    rate_multipliers_: uint256[N_COINS],
    rate_oracles_: address[N_COINS],
    call_amount_: uint256[N_COINS],
    scale_factor_: uint256[N_COINS],
):
    for i: uint256 in range(N_COINS):
        self.coins[i] = coins_[i]
        self.asset_types[i] = asset_types_[i]
        self.rate_multipliers[i] = rate_multipliers_[i]
        self.rate_oracles[i] = rate_oracles_[i]
        self.call_amount[i] = call_amount_[i]
        self.scale_factor[i] = scale_factor_[i]


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
                * staticcall ERC4626(self.coins[i]).convertToAssets(self.call_amount[i])
                * self.scale_factor[i]
                //
                PRECISION
            )

    return rates


@external
@view
def stored_rates() -> uint256[N_COINS]:
    return self._stored_rates()


@external
@view
def xp_from_balances(balances: uint256[N_COINS]) -> uint256[N_COINS]:
    rates: uint256[N_COINS] = self._stored_rates()
    xp: uint256[N_COINS] = empty(uint256[N_COINS])

    for i: uint256 in range(N_COINS):
        xp[i] = balances[i] * rates[i] // PRECISION

    return xp
