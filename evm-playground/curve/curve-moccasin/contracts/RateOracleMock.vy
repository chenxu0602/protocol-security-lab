# pragma version ^0.4.0

rate: public(uint256)
should_revert: public(bool)


@deploy
def __init__(rate_: uint256):
    self.rate = rate_


@external
def set_rate(rate_: uint256):
    self.rate = rate_


@external
def set_should_revert(should_revert_: bool):
    self.should_revert = should_revert_


@external
@view
def get_rate() -> uint256:
    assert not self.should_revert, "oracle revert"
    return self.rate
