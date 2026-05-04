# pragma version ^0.4.0

name: public(String[32])
symbol: public(String[16])
decimals: public(uint8)
totalSupply: public(uint256)

balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])


@deploy
def __init__(name_: String[32], symbol_: String[16], decimals_: uint8):
    self.name = name_
    self.symbol = symbol_
    self.decimals = decimals_


@external
def mint(to: address, amount: uint256):
    self.balanceOf[to] += amount
    self.totalSupply += amount


@external
def rebase(to: address, amount: uint256):
    self.balanceOf[to] += amount
    self.totalSupply += amount


@external
def approve(spender: address, amount: uint256) -> bool:
    self.allowance[msg.sender][spender] = amount
    return True


@external
def transfer(to: address, amount: uint256) -> bool:
    assert self.balanceOf[msg.sender] >= amount, "insufficient balance"

    self.balanceOf[msg.sender] -= amount
    self.balanceOf[to] += amount
    return True


@external
def transferFrom(sender: address, to: address, amount: uint256) -> bool:
    allowed: uint256 = self.allowance[sender][msg.sender]
    assert allowed >= amount, "insufficient allowance"
    assert self.balanceOf[sender] >= amount, "insufficient balance"

    self.allowance[sender][msg.sender] = allowed - amount
    self.balanceOf[sender] -= amount
    self.balanceOf[to] += amount
    return True
