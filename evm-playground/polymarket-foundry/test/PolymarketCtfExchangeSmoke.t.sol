// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import {IERC20} from "polymarket/ctf-exchange/src/common/interfaces/IERC20.sol";

contract PolymarketCtfExchangeSmokeTest {
    function test_ctfExchangeImportPathCompiles() external pure {
        IERC20 token;
        require(address(token) == address(0), "unexpected token");
    }
}
