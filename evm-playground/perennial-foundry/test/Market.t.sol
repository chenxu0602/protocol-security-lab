// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { Market } from "perennial-v2/packages/core/contracts/Market.sol";
import { MockToken } from "perennial-v2/packages/core/contracts/test/MockToken.sol";
import { OracleVersion } from "perennial-v2/packages/core/contracts/types/OracleVersion.sol";

import { Fixed6Lib } from "@equilibria/root/number/types/Fixed6.sol";
import { Token18 } from "@equilibria/root/token/types/Token18.sol";

import { MockMarket } from "src/mocks/MockMarket.sol";
import { MockOracleProvider } from "src/mocks/MockOracleProvider.sol";
import { MockVerifier } from "src/mocks/MockVerifier.sol";
import { MockMarketFactory } from "src/mocks/MockMarketFactory.sol";

contract MarketTest is Test {
    MockToken internal token;
    MockOracleProvider internal oracle;
    MockMarket internal deployer;
    MockVerifier internal verifier;
    MockMarketFactory internal factory;
    Market internal market;

    function setUp() public {
        token = new MockToken();
        oracle = new MockOracleProvider();
        deployer = new MockMarket();

        oracle.setStatus(
            OracleVersion({
                timestamp: block.timestamp,
                price: Fixed6Lib.from(2000e6),
                valid: true
            }),
            block.timestamp + 1
        );

        (market, factory, verifier) = deployer.create(address(token), oracle);
    }

    function test_initialize_sets_factory_token_and_oracle() public view {
        assertEq(address(market.factory()), address(factory));
        assertEq(Token18.unwrap(market.token()), address(token));
        assertEq(address(market.oracle()), address(oracle));
    }
}
