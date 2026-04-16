// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import {
    ExchangeInitParams,
    MatchType,
    Order,
    ORDER_TYPEHASH,
    OrderStatus,
    Side,
    SignatureType
} from "polymarket/ctf-exchange-v2/src/exchange/libraries/Structs.sol";

contract PolymarketCtfExchangeV2SmokeTest {
    function test_ctfExchangeV2ImportPathCompiles() external pure {
        ExchangeInitParams memory params;
        Order memory order;
        OrderStatus memory status;

        require(params.admin == address(0), "unexpected admin");
        require(order.maker == address(0), "unexpected maker");
        require(status.remaining == 0, "unexpected remaining");
        require(uint256(Side.BUY) == 0, "unexpected buy enum");
        require(uint256(MatchType.COMPLEMENTARY) == 0, "unexpected match enum");
        require(uint256(SignatureType.EOA) == 0, "unexpected signature enum");
        require(ORDER_TYPEHASH != bytes32(0), "unexpected order typehash");
    }
}
