# pragma version ^0.4.0

interface ERC20:
    def balanceOf(account: address) -> uint256: view
    def transfer(to: address, amount: uint256) -> bool: nonpayable
    def transferFrom(sender: address, to: address, amount: uint256) -> bool: nonpayable


name: public(String[32])
symbol: public(String[16])
decimals: public(uint8)
asset: public(address)
totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])


@deploy
def __init__(asset_: address, name_: String[32], symbol_: String[16], decimals_: uint8):
    self.asset = asset_
    self.name = name_
    self.symbol = symbol_
    self.decimals = decimals_


@view
@external
def totalAssets() -> uint256:
    return staticcall ERC20(self.asset).balanceOf(self)


@view
@external
def convertToAssets(shares: uint256) -> uint256:
    supply: uint256 = self.totalSupply
    if supply == 0:
        return shares
    return shares * staticcall ERC20(self.asset).balanceOf(self) // supply


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


@external
def deposit(assets: uint256, receiver: address) -> uint256:
    assert assets > 0, "zero assets"

    total_assets: uint256 = staticcall ERC20(self.asset).balanceOf(self)
    supply: uint256 = self.totalSupply
    shares: uint256 = 0

    if supply == 0 or total_assets == 0:
        shares = assets
    else:
        shares = assets * supply // total_assets

    assert shares > 0, "zero shares"
    assert extcall ERC20(self.asset).transferFrom(msg.sender, self, assets), "transfer failed"

    self.balanceOf[receiver] += shares
    self.totalSupply = supply + shares
    return shares
