# pragma version ^0.4.0

interface ERC20:
    def balanceOf(account: address) -> uint256: view
    def transfer(to: address, amount: uint256) -> bool: nonpayable


@external
@view
def leftover(token: address) -> uint256:
    return staticcall ERC20(token).balanceOf(self)


@external
def flush_full_balance(token: address, receiver: address) -> uint256:
    assert receiver != empty(address)
    amount: uint256 = staticcall ERC20(token).balanceOf(self)
    if amount > 0:
        assert extcall ERC20(token).transfer(receiver, amount), "transfer failed"
    return amount
