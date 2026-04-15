// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

contract MockTickMath {
    function minTick() external pure returns (int24) {
        return TickMath.MIN_TICK;
    }

    function maxTick() external pure returns (int24) {
        return TickMath.MAX_TICK;
    }

    function minSqrtRatio() external pure returns (uint160) {
        return TickMath.MIN_SQRT_RATIO;
    }

    function maxSqrtRatio() external pure returns (uint160) {
        return TickMath.MAX_SQRT_RATIO;
    }

    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function getTickAtSqrtRatio(uint160 sqrtPriceX96) external pure returns (int24) {
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }
}
