# pragma version ^0.4.0

PRECISION: constant(uint256) = 10**18
FEE_DENOMINATOR: constant(uint256) = 10**10


@external
@pure
def admin_fee_raw_from_dy_fee_xp(
    dy_fee_xp: uint256,
    rate_j: uint256,
    admin_fee: uint256,
) -> uint256:
    """
    Convert fee first computed in normalized xp units back into raw token units.
    Mirrors the NG path:
      admin_raw = (dy_fee_xp * admin_fee / FEE_DENOMINATOR) * PRECISION / rate_j
    """
    return (dy_fee_xp * admin_fee // FEE_DENOMINATOR) * PRECISION // rate_j


@external
@pure
def raw_to_xp(raw_amount: uint256, rate: uint256) -> uint256:
    return raw_amount * rate // PRECISION


@external
@pure
def xp_to_raw(xp_amount: uint256, rate: uint256) -> uint256:
    return xp_amount * PRECISION // rate
