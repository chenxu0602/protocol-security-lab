// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IFeeModule} from "polymarket/exchange-fee-module/src/interfaces/IFeeModule.sol";

contract PolymarketExchangeFeeModuleSmokeTest {
    function test_exchangeFeeModuleImportPathCompiles() external pure {
        IFeeModule module;
        require(address(module) == address(0), "unexpected fee module");
    }
}
