// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { TestERC20 } from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import { UniswapV3Factory } from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";

contract MockUniswapV3Factory {
    function createFactory() external returns (UniswapV3Factory factory) {
        factory = new UniswapV3Factory();
    }

    function createTokens(uint256 mint0, uint256 mint1) external returns (TestERC20 token0, TestERC20 token1) {
        token0 = new TestERC20(0);
        token1 = new TestERC20(0);

        if (mint0 > 0) token0.mint(msg.sender, mint0);
        if (mint1 > 0) token1.mint(msg.sender, mint1);
    }

    function createFactoryAndPool(uint24 fee, uint160 sqrtPriceX96)
        external
        returns (
            UniswapV3Factory factory,
            address pool,
            TestERC20 token0,
            TestERC20 token1
        )
    {
        factory = new UniswapV3Factory();
        token0 = new TestERC20(0);
        token1 = new TestERC20(0);

        pool = factory.createPool(address(token0), address(token1), fee);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
    }

    function createPool(
        UniswapV3Factory factory,
        address tokenA,
        address tokenB,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address pool) {
        pool = factory.createPool(tokenA, tokenB, fee);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
    }
}
