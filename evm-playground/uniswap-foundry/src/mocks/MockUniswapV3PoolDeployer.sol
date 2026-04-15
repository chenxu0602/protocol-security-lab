// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { UniswapV3PoolDeployer } from "@uniswap/v3-core/contracts/UniswapV3PoolDeployer.sol";

contract MockUniswapV3PoolDeployer is UniswapV3PoolDeployer {
    function deployPool(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) external returns (address pool) {
        pool = deploy(factory, token0, token1, fee, tickSpacing);
    }

    function deployAndInitializePool(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address pool) {
        pool = deploy(factory, token0, token1, fee, tickSpacing);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
    }

    function parametersSnapshot()
        external
        view
        returns (
            address factory,
            address token0,
            address token1,
            uint24 fee,
            int24 tickSpacing
        )
    {
        Parameters memory params = parameters;
        return (params.factory, params.token0, params.token1, params.fee, params.tickSpacing);
    }
}
