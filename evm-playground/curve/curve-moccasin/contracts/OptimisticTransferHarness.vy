# pragma version ^0.4.0

interface ERC20:
    def balanceOf(account: address) -> uint256: view


N_COINS: constant(uint256) = 2
ASSET_TYPE_PLAIN: constant(uint256) = 0
ASSET_TYPE_REBASING: constant(uint256) = 2

coins: public(address[N_COINS])
asset_types: public(uint256[N_COINS])
stored_balances: public(uint256[N_COINS])


@deploy
def __init__(coins_: address[N_COINS], asset_types_: uint256[N_COINS]):
    for i: uint256 in range(N_COINS):
        self.coins[i] = coins_[i]
        self.asset_types[i] = asset_types_[i]


@internal
@view
def _has_rebasing_asset() -> bool:
    for i: uint256 in range(N_COINS):
        if self.asset_types[i] == ASSET_TYPE_REBASING:
            return True
    return False


@external
@view
def has_rebasing_asset() -> bool:
    return self._has_rebasing_asset()


@external
@view
def actual_balance(i: uint256) -> uint256:
    assert i < N_COINS
    return staticcall ERC20(self.coins[i]).balanceOf(self)


@external
def set_stored_balance(i: uint256, amount: uint256):
    assert i < N_COINS
    self.stored_balances[i] = amount


@external
def sync_stored_balance(i: uint256):
    assert i < N_COINS
    self.stored_balances[i] = staticcall ERC20(self.coins[i]).balanceOf(self)


@external
@view
def preview_exchange_received(i: uint256) -> uint256:
    assert i < N_COINS
    assert not self._has_rebasing_asset(), "rebasing asset"

    actual: uint256 = staticcall ERC20(self.coins[i]).balanceOf(self)
    assert actual >= self.stored_balances[i], "negative delta"
    return actual - self.stored_balances[i]


@external
def exchange_received(i: uint256) -> uint256:
    assert i < N_COINS
    assert not self._has_rebasing_asset(), "rebasing asset"

    actual: uint256 = staticcall ERC20(self.coins[i]).balanceOf(self)
    assert actual >= self.stored_balances[i], "negative delta"

    optimistic_input: uint256 = actual - self.stored_balances[i]
    self.stored_balances[i] = actual
    return optimistic_input
