// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {PanopticMath} from 'panoptic-v2-core/contracts/libraries/PanopticMath.sol';
import {OraclePack, OraclePackLibrary} from 'panoptic-v2-core/contracts/types/OraclePack.sol';
import {TokenId} from 'panoptic-v2-core/contracts/types/TokenId.sol';

contract TokenOracleEdgeHarness {
    function getMedianTick(OraclePack oraclePack) external pure returns (int24) {
        return oraclePack.getMedianTick();
    }

    function getTicks(
        int24 strike,
        int24 width,
        int24 tickSpacing
    ) external pure returns (int24 tickLower, int24 tickUpper) {
        return PanopticMath.getTicks(strike, width, tickSpacing);
    }
}

contract PanopticTokenOracleEdgePoCsTest is Test {
    TokenOracleEdgeHarness internal harness;

    function setUp() public {
        harness = new TokenOracleEdgeHarness();
    }

    function test_countLegsAndLongs_tracksMixedPositionShape() external pure {
        TokenId mixed = TokenId.wrap(0)
            .addTickSpacing(1)
            .addLeg(0, 1, 0, 0, 0, 0, 10, 2)
            .addLeg(1, 1, 1, 1, 1, 1, 20, 4)
            .addLeg(2, 1, 0, 1, 0, 2, 30, 0);

        assertEq(mixed.countLegs(), 3);
        assertEq(mixed.countLongs(), 2);
    }

    function test_getMedianTick_negativeOddAverageRoundsTowardZero() external view {
        int16[8] memory sortedResiduals = [
            int16(-4),
            int16(-3),
            int16(-2),
            int16(-1),
            int16(0),
            int16(1),
            int16(2),
            int16(3)
        ];
        OraclePack oraclePack = _sortedOraclePack(0, sortedResiduals);

        // rank3 = -1 and rank4 = 0, so Solidity signed division rounds (-1 / 2) toward zero.
        assertEq(harness.getMedianTick(oraclePack), 0);
    }

    function test_getTicks_reconstructsRangeAroundStrike() external view {
        (int24 tickLower, int24 tickUpper) = harness.getTicks(120, 6, 5);

        assertEq(tickLower, 105);
        assertEq(tickUpper, 135);
    }

    function _sortedOraclePack(
        int24 referenceTick,
        int16[8] memory sortedResiduals
    ) internal pure returns (OraclePack oraclePack) {
        uint256 packedResiduals;
        for (uint8 i = 0; i < 8; ++i) {
            packedResiduals |= (uint256(uint16(sortedResiduals[i])) & 0x0FFF) << (i * 12);
        }

        return
            OraclePackLibrary.storeOraclePack(
                0,
                uint256(0xFAC688),
                0,
                referenceTick,
                uint96(packedResiduals >> 12),
                int24(sortedResiduals[0]),
                0
            );
    }
}
