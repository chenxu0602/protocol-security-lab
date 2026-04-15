// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import { Oracle } from "@uniswap/v3-core/contracts/libraries/Oracle.sol";

contract MockOracle {
    using Oracle for Oracle.Observation[65535];

    Oracle.Observation[65535] internal observations;

    uint16 public index;
    uint16 public cardinality;
    uint16 public cardinalityNext;

    function initialize(uint32 time) external returns (uint16 cardinality_, uint16 cardinalityNext_) {
        (cardinality, cardinalityNext) = observations.initialize(time);
        index = 0;
        return (cardinality, cardinalityNext);
    }

    function grow(uint16 next) external returns (uint16 cardinalityNext_) {
        cardinalityNext = observations.grow(cardinalityNext, next);
        return cardinalityNext;
    }

    function write(
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity
    ) external returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        (index, cardinality) =
            observations.write(index, blockTimestamp, tick, liquidity, cardinality, cardinalityNext);
        return (index, cardinality);
    }

    function observeSingle(
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint128 liquidity
    ) external view returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) {
        return observations.observeSingle(time, secondsAgo, tick, index, liquidity, cardinality);
    }

    function observe(
        uint32 time,
        uint32[] calldata secondsAgos,
        int24 tick,
        uint128 liquidity
    ) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
        uint32[] memory copied = secondsAgos;
        return observations.observe(time, copied, tick, index, liquidity, cardinality);
    }

    function getObservation(uint256 observationIndex)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        Oracle.Observation storage observation = observations[observationIndex];
        return (
            observation.blockTimestamp,
            observation.tickCumulative,
            observation.secondsPerLiquidityCumulativeX128,
            observation.initialized
        );
    }
}
