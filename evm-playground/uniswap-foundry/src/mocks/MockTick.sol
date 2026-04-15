// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

import { Tick } from "@uniswap/v3-core/contracts/libraries/Tick.sol";

contract MockTick {
    using Tick for mapping(int24 => Tick.Info);

    mapping(int24 => Tick.Info) internal ticks;

    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) external pure returns (uint128) {
        return Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing);
    }

    function updateTick(
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time,
        bool upper,
        uint128 maxLiquidity
    ) external returns (bool flipped) {
        flipped = ticks.update(
            tick,
            tickCurrent,
            liquidityDelta,
            feeGrowthGlobal0X128,
            feeGrowthGlobal1X128,
            secondsPerLiquidityCumulativeX128,
            tickCumulative,
            time,
            upper,
            maxLiquidity
        );
    }

    function clearTick(int24 tick) external {
        ticks.clear(tick);
    }

    function crossTick(
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) external returns (int128 liquidityNet) {
        liquidityNet = ticks.cross(
            tick,
            feeGrowthGlobal0X128,
            feeGrowthGlobal1X128,
            secondsPerLiquidityCumulativeX128,
            tickCumulative,
            time
        );
    }

    function getFeeGrowthInside(
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) external view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        return ticks.getFeeGrowthInside(tickLower, tickUpper, tickCurrent, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
    }

    function getTickInfo(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        )
    {
        Tick.Info storage info = ticks[tick];
        return (
            info.liquidityGross,
            info.liquidityNet,
            info.feeGrowthOutside0X128,
            info.feeGrowthOutside1X128,
            info.tickCumulativeOutside,
            info.secondsPerLiquidityOutsideX128,
            info.secondsOutside,
            info.initialized
        );
    }
}
