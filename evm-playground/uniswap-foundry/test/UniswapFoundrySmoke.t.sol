// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract UniswapFoundrySmokeTest {
    function test_coreRemappingIsAvailable() external pure {
        require(TickMath.MIN_TICK == -887272, "unexpected MIN_TICK");
        require(TickMath.MAX_TICK == 887272, "unexpected MAX_TICK");
    }

    function test_peripheryRemappingIsAvailable() external pure {
        ISwapRouter.ExactInputSingleParams memory params;
        params.fee = 3000;

        require(params.fee == 3000, "unexpected fee");
    }

    function test_coreInterfaceCompiles() external pure {
        IUniswapV3Factory factory;

        require(address(factory) == address(0), "unexpected factory");
    }
}
