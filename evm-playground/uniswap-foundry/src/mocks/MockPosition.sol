// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

import { Position } from "@uniswap/v3-core/contracts/libraries/Position.sol";

contract MockPosition {
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    mapping(bytes32 => Position.Info) internal positions;

    function getPositionKey(
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    function updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) external {
        Position.Info storage position = positions.get(owner, tickLower, tickUpper);
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);
    }

    function getPosition(
        address owner,
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position.Info storage position = positions.get(owner, tickLower, tickUpper);
        return (
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }
}
