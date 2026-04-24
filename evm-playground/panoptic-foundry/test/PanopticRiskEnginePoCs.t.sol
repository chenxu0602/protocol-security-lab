// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Errors} from 'panoptic-v2-core/contracts/libraries/Errors.sol';
import {RiskEngine} from 'panoptic-v2-core/contracts/RiskEngine.sol';
import {LeftRightUnsigned, LeftRightSigned} from 'panoptic-v2-core/contracts/types/LeftRight.sol';
import {MarketState, MarketStateLibrary} from 'panoptic-v2-core/contracts/types/MarketState.sol';
import {OraclePack, OraclePackLibrary} from 'panoptic-v2-core/contracts/types/OraclePack.sol';
import {TokenId} from 'panoptic-v2-core/contracts/types/TokenId.sol';

contract RiskEnginePoCHarness is RiskEngine {
    constructor() RiskEngine(10_000_000, 10_000_000, address(0), address(0)) {}

    function requiredCollateralSinglePosition(
        TokenId tokenId,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization,
        bool underlyingIsToken0
    ) external pure returns (uint256 tokenRequired, uint256 credits) {
        return
            _getRequiredCollateralAtTickSinglePosition(
                tokenId,
                positionSize,
                atTick,
                poolUtilization,
                underlyingIsToken0
            );
    }

    function rebaseOraclePack(
        OraclePack oraclePack
    ) external pure returns (int24 newReferenceTick, OraclePack rebasedOraclePack) {
        return oraclePack.rebaseOraclePack();
    }
}

contract PanopticRiskEnginePoCsTest is Test {
    using MarketStateLibrary for MarketState;

    RiskEnginePoCHarness internal harness;

    function setUp() public {
        harness = new RiskEnginePoCHarness();
    }

    function test_getLiquidationBonus_distributionInsolventShapeDoesNotUnderflow() external view {
        LeftRightUnsigned tokenData0 = LeftRightUnsigned.wrap(0)
            .addToRightSlot(1_000)
            .addToLeftSlot(100);
        LeftRightUnsigned tokenData1 = LeftRightUnsigned.wrap(0)
            .addToRightSlot(1)
            .addToLeftSlot(2_000);

        (LeftRightSigned bonus, LeftRightSigned collateralRemaining) = harness.getLiquidationBonus(
            tokenData0,
            tokenData1,
            uint160(2 ** 96),
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        assertEq(bonus.rightSlot(), 0);
        assertEq(bonus.leftSlot(), 0);
        assertEq(collateralRemaining.rightSlot(), 1_000);
        assertEq(collateralRemaining.leftSlot(), 1);
    }

    function test_requiredCollateralSinglePosition_accumulatesCreditsAcrossMatchingLegs()
        external
        view
    {
        TokenId firstCredit = TokenId.wrap(0)
            .addTickSpacing(1)
            .addLeg(0, 1, 0, 1, 0, 0, 0, 0);
        TokenId secondCredit = TokenId.wrap(0)
            .addTickSpacing(1)
            .addLeg(0, 1, 0, 1, 0, 0, 0, 0)
            .addLeg(1, 1, 0, 1, 0, 1, 5, 0);

        (, uint256 firstCredits) = harness.requiredCollateralSinglePosition(
            firstCredit,
            7,
            0,
            0,
            true
        );
        (, uint256 combinedCredits) = harness.requiredCollateralSinglePosition(
            secondCredit,
            7,
            0,
            0,
            true
        );

        assertEq(firstCredits, 7);
        assertEq(combinedCredits, 14);
    }

    function test_twapEMA_weightsFastSlowEonsAndIgnoresSpot() external view {
        OraclePack oraclePackA = _oraclePack({spot: 7_777, fast: 300, slow: 200, eons: 100});
        OraclePack oraclePackB = _oraclePack({spot: -7_777, fast: 300, slow: 200, eons: 100});

        int24 twapA = harness.twapEMA(oraclePackA);
        int24 twapB = harness.twapEMA(oraclePackB);

        assertEq(twapA, 250);
        assertEq(twapB, 250);
    }

    function test_rebaseOraclePack_preservesLockModeAndEmas() external view {
        OraclePack original = OraclePackLibrary.storeOraclePack(
            77,
            0,
            OraclePackLibrary.packEMAs(11, 22, 33, 44),
            3_000,
            uint96(0),
            0,
            3
        );

        (, OraclePack rebased) = harness.rebaseOraclePack(original);

        (int24 spot, int24 fast, int24 slow, int24 eons, ) = rebased.getEMAs();
        assertEq(rebased.lockMode(), 3);
        assertEq(spot, 11);
        assertEq(fast, 22);
        assertEq(slow, 33);
        assertEq(eons, 44);
    }

    function test_requiredCollateralSinglePosition_widthOneLongAtStrikeNoLongerDividesByZero()
        external
        view
    {
        TokenId widthOneLong = TokenId.wrap(0)
            .addTickSpacing(1)
            .addLeg(0, 1, 0, 1, 0, 0, 0, 1);

        (uint256 tokenRequired, uint256 credits) = harness.requiredCollateralSinglePosition(
            widthOneLong,
            5,
            0,
            0,
            true
        );

        assertGt(tokenRequired, 0);
        assertEq(credits, 0);
    }

    function test_requiredCollateralSinglePosition_wideRangeShortStillRevertsInvalidTick() external {
        TokenId wideShort = TokenId.wrap(0)
            .addTickSpacing(1_000)
            .addLeg(0, 1, 0, 0, 0, 0, 0, 1_000);

        vm.expectRevert(Errors.InvalidTick.selector);
        harness.requiredCollateralSinglePosition(wideShort, 1, 0, 0, true);
    }

    function test_getSolvencyTicks_safeModeForcesFourTickChecksOnSymmetricBlindSpotShape()
        external
        view
    {
        OraclePack oraclePack = OraclePackLibrary.storeOraclePack(
            0,
            0,
            OraclePackLibrary.packEMAs(500, 0, 0, 0),
            0,
            uint96(0),
            0,
            0
        );

        (int24[] memory baselineTicks, ) = harness.getSolvencyTicks(-500, oraclePack, 0);
        (int24[] memory safeModeTicks, ) = harness.getSolvencyTicks(-500, oraclePack, 1);

        assertEq(baselineTicks.length, 1);
        assertEq(baselineTicks[0], 500);
        assertEq(safeModeTicks.length, 4);
        assertEq(safeModeTicks[0], 500);
        assertEq(safeModeTicks[1], 0);
        assertEq(safeModeTicks[2], 0);
        assertEq(safeModeTicks[3], -500);
    }

    function test_updateInterestRate_sameEpochDoesNotCompoundRateAtTarget() external view {
        uint32 currentEpoch = uint32(block.timestamp >> 2);
        MarketState accumulator = MarketStateLibrary.storeMarketState(
            1e18,
            currentEpoch,
            uint256(0.04 ether / int256(365 days)),
            0
        );

        (, uint256 nextRate) = harness.updateInterestRate(0, accumulator);

        assertEq(nextRate, accumulator.rateAtTarget());
    }

    function _oraclePack(
        int24 spot,
        int24 fast,
        int24 slow,
        int24 eons
    ) internal pure returns (OraclePack) {
        return
            OraclePackLibrary.storeOraclePack(
                0,
                0,
                OraclePackLibrary.packEMAs(spot, fast, slow, eons),
                0,
                uint96(0),
                0,
                0
            );
    }
}
