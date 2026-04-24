// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

contract LiquidationSemanticsHarness {
    struct SignedPair {
        int256 token0;
        int256 token1;
    }

    struct UnsignedPair {
        uint256 token0;
        uint256 token1;
    }

    struct EligibilityView {
        uint256 shortToken0;
        uint256 shortToken1;
    }

    struct LiquidationOutcome {
        uint256 eligibilityShortToken0;
        uint256 eligibilityShortToken1;
        int256 baseBonusToken0;
        int256 baseBonusToken1;
        int256 finalBonusToken0;
        int256 finalBonusToken1;
        uint256 settledLongToken0;
        uint256 settledLongToken1;
        int256 liquidateeCollateralToken0;
        int256 liquidateeCollateralToken1;
        int256 liquidatorCollateralToken0;
        int256 liquidatorCollateralToken1;
    }

    function eligibilitySnapshot(
        UnsignedPair memory availableShortPremium,
        SignedPair memory theoreticalShortPremium
    ) public pure returns (EligibilityView memory viewData) {
        theoreticalShortPremium;
        viewData.shortToken0 = availableShortPremium.token0;
        viewData.shortToken1 = availableShortPremium.token1;
    }

    function runLiquidation(
        UnsignedPair memory availableShortPremium,
        SignedPair memory theoreticalShortPremium,
        SignedPair memory rawLongPremiumToCommit,
        SignedPair memory haircutOnLongPremium,
        SignedPair memory baseBonus,
        SignedPair memory bonusDelta,
        UnsignedPair memory haircutTotal,
        SignedPair memory startingLiquidateeCollateral
    ) external pure returns (LiquidationOutcome memory outcome) {
        EligibilityView memory viewData = eligibilitySnapshot(availableShortPremium, theoreticalShortPremium);

        outcome.eligibilityShortToken0 = viewData.shortToken0;
        outcome.eligibilityShortToken1 = viewData.shortToken1;

        outcome.baseBonusToken0 = baseBonus.token0;
        outcome.baseBonusToken1 = baseBonus.token1;
        outcome.finalBonusToken0 = baseBonus.token0 + bonusDelta.token0;
        outcome.finalBonusToken1 = baseBonus.token1 + bonusDelta.token1;

        // Liquidation commits long premium only after haircut has been computed.
        outcome.settledLongToken0 = _positive(-(rawLongPremiumToCommit.token0 + haircutOnLongPremium.token0));
        outcome.settledLongToken1 = _positive(-(rawLongPremiumToCommit.token1 + haircutOnLongPremium.token1));

        outcome.liquidateeCollateralToken0 =
            startingLiquidateeCollateral.token0 -
            int256(haircutTotal.token0) -
            outcome.finalBonusToken0;
        outcome.liquidateeCollateralToken1 =
            startingLiquidateeCollateral.token1 -
            int256(haircutTotal.token1) -
            outcome.finalBonusToken1;

        outcome.liquidatorCollateralToken0 =
            int256(haircutTotal.token0) +
            outcome.finalBonusToken0;
        outcome.liquidatorCollateralToken1 =
            int256(haircutTotal.token1) +
            outcome.finalBonusToken1;
    }

    function _positive(int256 value) internal pure returns (uint256) {
        return value > 0 ? uint256(value) : 0;
    }
}

contract PanopticLiquidationSemanticsTest is Test {
    LiquidationSemanticsHarness internal harness;

    function setUp() public {
        harness = new LiquidationSemanticsHarness();
    }

    function test_eligibilitySnapshot_usesAvailableShortPremiumNotTheoretical() external view {
        LiquidationSemanticsHarness.EligibilityView memory viewData = harness.eligibilitySnapshot(
            LiquidationSemanticsHarness.UnsignedPair(6, 2),
            LiquidationSemanticsHarness.SignedPair(30, 12)
        );

        assertEq(viewData.shortToken0, 6);
        assertEq(viewData.shortToken1, 2);
    }

    function test_runLiquidation_commitsLongPremiumOnlyAfterHaircutAdjustment() external view {
        LiquidationSemanticsHarness.LiquidationOutcome memory outcome = harness.runLiquidation(
            LiquidationSemanticsHarness.UnsignedPair(4, 1),
            LiquidationSemanticsHarness.SignedPair(20, 8),
            LiquidationSemanticsHarness.SignedPair(-15, -9),
            LiquidationSemanticsHarness.SignedPair(6, 2),
            LiquidationSemanticsHarness.SignedPair(0, 0),
            LiquidationSemanticsHarness.SignedPair(0, 0),
            LiquidationSemanticsHarness.UnsignedPair(6, 2),
            LiquidationSemanticsHarness.SignedPair(100, 80)
        );

        assertEq(outcome.settledLongToken0, 9);
        assertEq(outcome.settledLongToken1, 7);
    }

    function test_runLiquidation_bonusDeltaAdjustsSettlementBeforeFinalReconciliation()
        external
        view
    {
        LiquidationSemanticsHarness.LiquidationOutcome memory outcome = harness.runLiquidation(
            LiquidationSemanticsHarness.UnsignedPair(5, 3),
            LiquidationSemanticsHarness.SignedPair(14, 10),
            LiquidationSemanticsHarness.SignedPair(-8, -6),
            LiquidationSemanticsHarness.SignedPair(0, 0),
            LiquidationSemanticsHarness.SignedPair(9, 4),
            LiquidationSemanticsHarness.SignedPair(-3, 7),
            LiquidationSemanticsHarness.UnsignedPair(2, 1),
            LiquidationSemanticsHarness.SignedPair(50, 40)
        );

        assertEq(outcome.baseBonusToken0, 9);
        assertEq(outcome.baseBonusToken1, 4);
        assertEq(outcome.finalBonusToken0, 6);
        assertEq(outcome.finalBonusToken1, 11);
        assertEq(outcome.liquidateeCollateralToken0, 42);
        assertEq(outcome.liquidateeCollateralToken1, 28);
    }

    function test_runLiquidation_negativeFinalBonusReversesTokenFlowDirection() external view {
        LiquidationSemanticsHarness.LiquidationOutcome memory outcome = harness.runLiquidation(
            LiquidationSemanticsHarness.UnsignedPair(0, 0),
            LiquidationSemanticsHarness.SignedPair(0, 0),
            LiquidationSemanticsHarness.SignedPair(0, 0),
            LiquidationSemanticsHarness.SignedPair(0, 0),
            LiquidationSemanticsHarness.SignedPair(3, 2),
            LiquidationSemanticsHarness.SignedPair(-8, -5),
            LiquidationSemanticsHarness.UnsignedPair(0, 0),
            LiquidationSemanticsHarness.SignedPair(20, 20)
        );

        assertEq(outcome.finalBonusToken0, -5);
        assertEq(outcome.finalBonusToken1, -3);
        assertEq(outcome.liquidateeCollateralToken0, 25);
        assertEq(outcome.liquidateeCollateralToken1, 23);
        assertEq(outcome.liquidatorCollateralToken0, -5);
        assertEq(outcome.liquidatorCollateralToken1, -3);
    }

    function test_runLiquidation_haircutAndBonusBothReduceLiquidateeFinalCollateral()
        external
        view
    {
        LiquidationSemanticsHarness.LiquidationOutcome memory outcome = harness.runLiquidation(
            LiquidationSemanticsHarness.UnsignedPair(7, 4),
            LiquidationSemanticsHarness.SignedPair(21, 9),
            LiquidationSemanticsHarness.SignedPair(-10, -7),
            LiquidationSemanticsHarness.SignedPair(2, 1),
            LiquidationSemanticsHarness.SignedPair(11, 5),
            LiquidationSemanticsHarness.SignedPair(1, -2),
            LiquidationSemanticsHarness.UnsignedPair(4, 3),
            LiquidationSemanticsHarness.SignedPair(70, 55)
        );

        assertEq(outcome.finalBonusToken0, 12);
        assertEq(outcome.finalBonusToken1, 3);
        assertEq(outcome.liquidateeCollateralToken0, 54);
        assertEq(outcome.liquidateeCollateralToken1, 49);
        assertEq(outcome.liquidatorCollateralToken0, 16);
        assertEq(outcome.liquidatorCollateralToken1, 6);
    }

    function test_runLiquidation_theoreticalShortPremiumDoesNotRewriteEligibilitySnapshot()
        external
        view
    {
        LiquidationSemanticsHarness.LiquidationOutcome memory lowAvailable = harness.runLiquidation(
            LiquidationSemanticsHarness.UnsignedPair(2, 1),
            LiquidationSemanticsHarness.SignedPair(50, 30),
            LiquidationSemanticsHarness.SignedPair(-5, -4),
            LiquidationSemanticsHarness.SignedPair(1, 1),
            LiquidationSemanticsHarness.SignedPair(7, 3),
            LiquidationSemanticsHarness.SignedPair(0, 0),
            LiquidationSemanticsHarness.UnsignedPair(1, 1),
            LiquidationSemanticsHarness.SignedPair(30, 30)
        );
        LiquidationSemanticsHarness.LiquidationOutcome memory highAvailable = harness.runLiquidation(
            LiquidationSemanticsHarness.UnsignedPair(12, 6),
            LiquidationSemanticsHarness.SignedPair(50, 30),
            LiquidationSemanticsHarness.SignedPair(-5, -4),
            LiquidationSemanticsHarness.SignedPair(1, 1),
            LiquidationSemanticsHarness.SignedPair(7, 3),
            LiquidationSemanticsHarness.SignedPair(0, 0),
            LiquidationSemanticsHarness.UnsignedPair(1, 1),
            LiquidationSemanticsHarness.SignedPair(30, 30)
        );

        assertEq(lowAvailable.eligibilityShortToken0, 2);
        assertEq(lowAvailable.eligibilityShortToken1, 1);
        assertEq(highAvailable.eligibilityShortToken0, 12);
        assertEq(highAvailable.eligibilityShortToken1, 6);
        assertEq(lowAvailable.finalBonusToken0, highAvailable.finalBonusToken0);
        assertEq(lowAvailable.finalBonusToken1, highAvailable.finalBonusToken1);
    }

    function test_sameInsolvency_differentEligibilitySnapshotYieldsDifferentEligibilityView()
        external
        view
    {
        LiquidationSemanticsHarness.LiquidationOutcome memory lowAvailable = _baselineOutcome(
            LiquidationSemanticsHarness.UnsignedPair(2, 1),
            LiquidationSemanticsHarness.SignedPair(40, 18),
            LiquidationSemanticsHarness.SignedPair(6, 3)
        );
        LiquidationSemanticsHarness.LiquidationOutcome memory highAvailable = _baselineOutcome(
            LiquidationSemanticsHarness.UnsignedPair(11, 5),
            LiquidationSemanticsHarness.SignedPair(40, 18),
            LiquidationSemanticsHarness.SignedPair(6, 3)
        );

        assertEq(lowAvailable.finalBonusToken0, highAvailable.finalBonusToken0);
        assertEq(lowAvailable.finalBonusToken1, highAvailable.finalBonusToken1);
        assertEq(lowAvailable.liquidateeCollateralToken0, highAvailable.liquidateeCollateralToken0);
        assertEq(lowAvailable.liquidateeCollateralToken1, highAvailable.liquidateeCollateralToken1);

        assertEq(lowAvailable.eligibilityShortToken0, 2);
        assertEq(lowAvailable.eligibilityShortToken1, 1);
        assertEq(highAvailable.eligibilityShortToken0, 11);
        assertEq(highAvailable.eligibilityShortToken1, 5);
    }

    function test_sameInsolvency_differentBonusSnapshotYieldsDifferentFinalCollateral()
        external
        view
    {
        LiquidationSemanticsHarness.LiquidationOutcome memory conservativeBonus = _baselineOutcome(
            LiquidationSemanticsHarness.UnsignedPair(4, 2),
            LiquidationSemanticsHarness.SignedPair(25, 10),
            LiquidationSemanticsHarness.SignedPair(1, 1)
        );
        LiquidationSemanticsHarness.LiquidationOutcome memory aggressiveBonus = harness
            .runLiquidation(
                LiquidationSemanticsHarness.UnsignedPair(4, 2),
                LiquidationSemanticsHarness.SignedPair(25, 10),
                LiquidationSemanticsHarness.SignedPair(-9, -6),
                LiquidationSemanticsHarness.SignedPair(2, 1),
                LiquidationSemanticsHarness.SignedPair(8, 4),
                LiquidationSemanticsHarness.SignedPair(6, -1),
                LiquidationSemanticsHarness.UnsignedPair(3, 2),
                LiquidationSemanticsHarness.SignedPair(60, 45)
            );

        assertEq(conservativeBonus.eligibilityShortToken0, aggressiveBonus.eligibilityShortToken0);
        assertEq(conservativeBonus.eligibilityShortToken1, aggressiveBonus.eligibilityShortToken1);
        assertEq(conservativeBonus.settledLongToken0, aggressiveBonus.settledLongToken0);
        assertEq(conservativeBonus.settledLongToken1, aggressiveBonus.settledLongToken1);

        assertEq(conservativeBonus.finalBonusToken0, 9);
        assertEq(conservativeBonus.finalBonusToken1, 5);
        assertEq(aggressiveBonus.finalBonusToken0, 14);
        assertEq(aggressiveBonus.finalBonusToken1, 3);
        assertEq(conservativeBonus.liquidateeCollateralToken0, 48);
        assertEq(conservativeBonus.liquidateeCollateralToken1, 38);
        assertEq(aggressiveBonus.liquidateeCollateralToken0, 43);
        assertEq(aggressiveBonus.liquidateeCollateralToken1, 40);
    }

    function test_sameInsolvency_differentHaircutSnapshotYieldsDifferentCommittedSettlement()
        external
        view
    {
        LiquidationSemanticsHarness.LiquidationOutcome memory lightHaircut = harness.runLiquidation(
            LiquidationSemanticsHarness.UnsignedPair(5, 3),
            LiquidationSemanticsHarness.SignedPair(30, 14),
            LiquidationSemanticsHarness.SignedPair(-12, -9),
            LiquidationSemanticsHarness.SignedPair(2, 1),
            LiquidationSemanticsHarness.SignedPair(8, 4),
            LiquidationSemanticsHarness.SignedPair(1, 1),
            LiquidationSemanticsHarness.UnsignedPair(2, 1),
            LiquidationSemanticsHarness.SignedPair(55, 44)
        );
        LiquidationSemanticsHarness.LiquidationOutcome memory deepHaircut = harness.runLiquidation(
            LiquidationSemanticsHarness.UnsignedPair(5, 3),
            LiquidationSemanticsHarness.SignedPair(30, 14),
            LiquidationSemanticsHarness.SignedPair(-12, -9),
            LiquidationSemanticsHarness.SignedPair(7, 5),
            LiquidationSemanticsHarness.SignedPair(8, 4),
            LiquidationSemanticsHarness.SignedPair(1, 1),
            LiquidationSemanticsHarness.UnsignedPair(7, 5),
            LiquidationSemanticsHarness.SignedPair(55, 44)
        );

        assertEq(lightHaircut.finalBonusToken0, deepHaircut.finalBonusToken0);
        assertEq(lightHaircut.finalBonusToken1, deepHaircut.finalBonusToken1);

        assertEq(lightHaircut.settledLongToken0, 10);
        assertEq(lightHaircut.settledLongToken1, 8);
        assertEq(deepHaircut.settledLongToken0, 5);
        assertEq(deepHaircut.settledLongToken1, 4);
        assertEq(lightHaircut.liquidateeCollateralToken0, 44);
        assertEq(lightHaircut.liquidateeCollateralToken1, 38);
        assertEq(deepHaircut.liquidateeCollateralToken0, 39);
        assertEq(deepHaircut.liquidateeCollateralToken1, 34);
    }

    function test_sameInsolvency_crossAssetBonusAdjustmentCreatesDifferentDirectionality()
        external
        view
    {
        LiquidationSemanticsHarness.LiquidationOutcome memory noCrossAssetShift = harness
            .runLiquidation(
                LiquidationSemanticsHarness.UnsignedPair(3, 2),
                LiquidationSemanticsHarness.SignedPair(18, 8),
                LiquidationSemanticsHarness.SignedPair(-6, -4),
                LiquidationSemanticsHarness.SignedPair(1, 1),
                LiquidationSemanticsHarness.SignedPair(5, 5),
                LiquidationSemanticsHarness.SignedPair(0, 0),
                LiquidationSemanticsHarness.UnsignedPair(2, 2),
                LiquidationSemanticsHarness.SignedPair(35, 35)
            );
        LiquidationSemanticsHarness.LiquidationOutcome memory crossAssetShift = harness
            .runLiquidation(
                LiquidationSemanticsHarness.UnsignedPair(3, 2),
                LiquidationSemanticsHarness.SignedPair(18, 8),
                LiquidationSemanticsHarness.SignedPair(-6, -4),
                LiquidationSemanticsHarness.SignedPair(1, 1),
                LiquidationSemanticsHarness.SignedPair(5, 5),
                LiquidationSemanticsHarness.SignedPair(-7, 9),
                LiquidationSemanticsHarness.UnsignedPair(2, 2),
                LiquidationSemanticsHarness.SignedPair(35, 35)
            );

        assertEq(noCrossAssetShift.eligibilityShortToken0, crossAssetShift.eligibilityShortToken0);
        assertEq(noCrossAssetShift.eligibilityShortToken1, crossAssetShift.eligibilityShortToken1);
        assertEq(noCrossAssetShift.settledLongToken0, crossAssetShift.settledLongToken0);
        assertEq(noCrossAssetShift.settledLongToken1, crossAssetShift.settledLongToken1);

        assertEq(noCrossAssetShift.finalBonusToken0, 5);
        assertEq(noCrossAssetShift.finalBonusToken1, 5);
        assertEq(crossAssetShift.finalBonusToken0, -2);
        assertEq(crossAssetShift.finalBonusToken1, 14);
        assertEq(noCrossAssetShift.liquidatorCollateralToken0, 7);
        assertEq(noCrossAssetShift.liquidatorCollateralToken1, 7);
        assertEq(crossAssetShift.liquidatorCollateralToken0, 0);
        assertEq(crossAssetShift.liquidatorCollateralToken1, 16);
    }

    function _baselineOutcome(
        LiquidationSemanticsHarness.UnsignedPair memory availableShortPremium,
        LiquidationSemanticsHarness.SignedPair memory theoreticalShortPremium,
        LiquidationSemanticsHarness.SignedPair memory bonusDelta
    ) internal view returns (LiquidationSemanticsHarness.LiquidationOutcome memory) {
        return
            harness.runLiquidation(
                availableShortPremium,
                theoreticalShortPremium,
                LiquidationSemanticsHarness.SignedPair(-9, -6),
                LiquidationSemanticsHarness.SignedPair(2, 1),
                LiquidationSemanticsHarness.SignedPair(8, 4),
                bonusDelta,
                LiquidationSemanticsHarness.UnsignedPair(3, 2),
                LiquidationSemanticsHarness.SignedPair(60, 45)
            );
    }
}
