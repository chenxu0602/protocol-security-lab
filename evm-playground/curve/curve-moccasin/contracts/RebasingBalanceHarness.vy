# pragma version ^0.4.0

interface ERC20:
    def balanceOf(account: address) -> uint256: view
    def transfer(to: address, amount: uint256) -> bool: nonpayable


N_COINS: constant(uint256) = 2
ASSET_TYPE_PLAIN: constant(uint256) = 0
ASSET_TYPE_REBASING: constant(uint256) = 2

coins: public(address[N_COINS])
asset_types: public(uint256[N_COINS])
stored_balances: public(uint256[N_COINS])
admin_balances: public(uint256[N_COINS])
total_supply: public(uint256)


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
def sync_stored_balance(i: uint256):
    assert i < N_COINS
    self.stored_balances[i] = staticcall ERC20(self.coins[i]).balanceOf(self)


@external
def set_admin_balance(i: uint256, amount: uint256):
    assert i < N_COINS
    self.admin_balances[i] = amount


@external
def set_total_supply(amount: uint256):
    self.total_supply = amount


@external
@view
def balances() -> uint256[N_COINS]:
    return self._balances()


@internal
@view
def _balances() -> uint256[N_COINS]:
    result: uint256[N_COINS] = empty(uint256[N_COINS])

    for i: uint256 in range(N_COINS):
        if self._has_rebasing_asset():
            result[i] = staticcall ERC20(self.coins[i]).balanceOf(self) - self.admin_balances[i]
        else:
            result[i] = self.stored_balances[i] - self.admin_balances[i]

    return result


@external
@view
def preview_remove_liquidity(burn_amount: uint256) -> uint256[N_COINS]:
    assert self.total_supply > 0

    result: uint256[N_COINS] = empty(uint256[N_COINS])
    live_balances: uint256[N_COINS] = self._balances()

    for i: uint256 in range(N_COINS):
        result[i] = live_balances[i] * burn_amount // self.total_supply

    return result


@external
def transfer_out(i: uint256, amount: uint256, receiver: address):
    assert i < N_COINS
    assert receiver != empty(address)

    if not self._has_rebasing_asset():
        self.stored_balances[i] -= amount
        assert extcall ERC20(self.coins[i]).transfer(receiver, amount), "transfer failed"
    else:
        coin_balance: uint256 = staticcall ERC20(self.coins[i]).balanceOf(self)
        assert extcall ERC20(self.coins[i]).transfer(receiver, amount), "transfer failed"
        self.stored_balances[i] = coin_balance - amount
