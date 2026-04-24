// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {TokenId} from 'panoptic-v2-core/contracts/types/TokenId.sol';

contract PremiumExerciseSemanticsHarness {
    struct SignedAmountPair {
        int256 token0;
        int256 token1;
    }

    struct UnsignedAmountPair {
        uint256 token0;
        uint256 token1;
    }

    struct PremiumTotals {
        uint256 shortToken0;
        uint256 shortToken1;
        uint256 longToken0;
        uint256 longToken1;
        int256 netToken0;
        int256 netToken1;
    }

    struct ExerciseComparison {
        int256 burnToken0;
        int256 burnToken1;
        int256 forceExerciseToken0;
        int256 forceExerciseToken1;
        int256 deltaToken0;
        int256 deltaToken1;
    }

    function aggregatePremia(
        TokenId tokenId,
        SignedAmountPair[4] memory rawPremiaByLeg,
        UnsignedAmountPair[4] memory availablePremiumByLeg,
        bool usePremiaAsCollateral,
        bool includePendingPremium
    ) external pure returns (PremiumTotals memory totals) {
        uint256 numLegs = tokenId.countLegs();

        for (uint256 leg = 0; leg < numLegs; ++leg) {
            if (tokenId.width(leg) == 0) continue;

            bool isLong = tokenId.isLong(leg) == 1;
            if (!isLong && !usePremiaAsCollateral) continue;

            SignedAmountPair memory premiaByLeg = rawPremiaByLeg[leg];
            if (isLong) {
                premiaByLeg.token0 = -premiaByLeg.token0;
                premiaByLeg.token1 = -premiaByLeg.token1;
            }

            if (!isLong) {
                if (includePendingPremium) {
                    totals.shortToken0 += uint256(premiaByLeg.token0);
                    totals.shortToken1 += uint256(premiaByLeg.token1);
                    totals.netToken0 += premiaByLeg.token0;
                    totals.netToken1 += premiaByLeg.token1;
                } else {
                    totals.shortToken0 += availablePremiumByLeg[leg].token0;
                    totals.shortToken1 += availablePremiumByLeg[leg].token1;
                    totals.netToken0 += int256(availablePremiumByLeg[leg].token0);
                    totals.netToken1 += int256(availablePremiumByLeg[leg].token1);
                }
            } else {
                totals.longToken0 += uint256(-premiaByLeg.token0);
                totals.longToken1 += uint256(-premiaByLeg.token1);
                totals.netToken0 += premiaByLeg.token0;
                totals.netToken1 += premiaByLeg.token1;
            }
        }
    }

    function compareBurnAndForceExercise(
        SignedAmountPair memory burnSettlement,
        SignedAmountPair memory exerciseFee
    ) external pure returns (ExerciseComparison memory comparison) {
        comparison.burnToken0 = burnSettlement.token0;
        comparison.burnToken1 = burnSettlement.token1;
        comparison.forceExerciseToken0 = burnSettlement.token0 + exerciseFee.token0;
        comparison.forceExerciseToken1 = burnSettlement.token1 + exerciseFee.token1;
        comparison.deltaToken0 = comparison.forceExerciseToken0 - comparison.burnToken0;
        comparison.deltaToken1 = comparison.forceExerciseToken1 - comparison.burnToken1;
    }
}

contract PanopticPremiumExerciseSemanticsTest is Test {
    PremiumExerciseSemanticsHarness internal harness;

    function setUp() public {
        harness = new PremiumExerciseSemanticsHarness();
    }

    function test_aggregatePremia_excludesShortCreditsWhenPremiaNotCollateralized() external view {
        TokenId tokenId = TokenId.wrap(0)
            .addLeg(0, 1, 0, 0, 0, 0, 0, 4)
            .addLeg(1, 1, 1, 1, 1, 1, 20, 3);

        PremiumExerciseSemanticsHarness.SignedAmountPair[4] memory rawPremiaByLeg;
        rawPremiaByLeg[0] = PremiumExerciseSemanticsHarness.SignedAmountPair(9, 4);
        rawPremiaByLeg[1] = PremiumExerciseSemanticsHarness.SignedAmountPair(7, 5);

        PremiumExerciseSemanticsHarness.PremiumTotals memory totals = harness.aggregatePremia(
            tokenId,
            rawPremiaByLeg,
            _emptyAvailablePremium(),
            false,
            true
        );

        assertEq(totals.shortToken0, 0);
        assertEq(totals.shortToken1, 0);
        assertEq(totals.longToken0, 7);
        assertEq(totals.longToken1, 5);
        assertEq(totals.netToken0, -7);
        assertEq(totals.netToken1, -5);
    }

    function test_aggregatePremia_includesTheoreticalShortCreditsWhenCollateralized() external view {
        TokenId tokenId = TokenId.wrap(0)
            .addLeg(0, 1, 0, 0, 0, 0, 0, 4)
            .addLeg(1, 1, 1, 1, 1, 1, 20, 3);

        PremiumExerciseSemanticsHarness.SignedAmountPair[4] memory rawPremiaByLeg;
        rawPremiaByLeg[0] = PremiumExerciseSemanticsHarness.SignedAmountPair(9, 4);
        rawPremiaByLeg[1] = PremiumExerciseSemanticsHarness.SignedAmountPair(7, 5);

        PremiumExerciseSemanticsHarness.PremiumTotals memory totals = harness.aggregatePremia(
            tokenId,
            rawPremiaByLeg,
            _emptyAvailablePremium(),
            true,
            true
        );

        assertEq(totals.shortToken0, 9);
        assertEq(totals.shortToken1, 4);
        assertEq(totals.longToken0, 7);
        assertEq(totals.longToken1, 5);
        assertEq(totals.netToken0, 2);
        assertEq(totals.netToken1, -1);
    }

    function test_aggregatePremia_shortCreditUsesAvailablePremiumWhenPendingExcluded() external view {
        TokenId shortOnly = TokenId.wrap(0).addLeg(0, 1, 0, 0, 0, 0, 0, 4);

        PremiumExerciseSemanticsHarness.SignedAmountPair[4] memory rawPremiaByLeg;
        rawPremiaByLeg[0] = PremiumExerciseSemanticsHarness.SignedAmountPair(15, 11);

        PremiumExerciseSemanticsHarness.UnsignedAmountPair[4] memory availablePremiumByLeg;
        availablePremiumByLeg[0] = PremiumExerciseSemanticsHarness.UnsignedAmountPair(6, 3);

        PremiumExerciseSemanticsHarness.PremiumTotals memory totals = harness.aggregatePremia(
            shortOnly,
            rawPremiaByLeg,
            availablePremiumByLeg,
            true,
            false
        );

        assertEq(totals.shortToken0, 6);
        assertEq(totals.shortToken1, 3);
        assertEq(totals.netToken0, 6);
        assertEq(totals.netToken1, 3);
    }

    function test_aggregatePremia_longDebitsPersistRegardlessOfCollateralFlag() external view {
        TokenId longOnly = TokenId.wrap(0).addLeg(0, 1, 0, 1, 0, 0, 0, 5);

        PremiumExerciseSemanticsHarness.SignedAmountPair[4] memory rawPremiaByLeg;
        rawPremiaByLeg[0] = PremiumExerciseSemanticsHarness.SignedAmountPair(12, 8);

        PremiumExerciseSemanticsHarness.PremiumTotals memory withoutShortCollateral = harness
            .aggregatePremia(longOnly, rawPremiaByLeg, _emptyAvailablePremium(), false, true);
        PremiumExerciseSemanticsHarness.PremiumTotals memory withShortCollateral = harness
            .aggregatePremia(longOnly, rawPremiaByLeg, _emptyAvailablePremium(), true, true);

        assertEq(withoutShortCollateral.longToken0, 12);
        assertEq(withoutShortCollateral.longToken1, 8);
        assertEq(withoutShortCollateral.netToken0, -12);
        assertEq(withoutShortCollateral.netToken1, -8);

        assertEq(withShortCollateral.longToken0, 12);
        assertEq(withShortCollateral.longToken1, 8);
        assertEq(withShortCollateral.netToken0, -12);
        assertEq(withShortCollateral.netToken1, -8);
    }

    function test_aggregatePremia_availablePremiumIsIgnoredWhenShortLegsNotCollateralized()
        external
        view
    {
        TokenId mixed = TokenId.wrap(0)
            .addLeg(0, 1, 0, 0, 0, 0, 0, 4)
            .addLeg(1, 1, 1, 1, 1, 1, 20, 3);

        PremiumExerciseSemanticsHarness.SignedAmountPair[4] memory rawPremiaByLeg;
        rawPremiaByLeg[0] = PremiumExerciseSemanticsHarness.SignedAmountPair(30, 12);
        rawPremiaByLeg[1] = PremiumExerciseSemanticsHarness.SignedAmountPair(9, 6);

        PremiumExerciseSemanticsHarness.UnsignedAmountPair[4] memory availablePremiumByLeg;
        availablePremiumByLeg[0] = PremiumExerciseSemanticsHarness.UnsignedAmountPair(13, 7);

        PremiumExerciseSemanticsHarness.PremiumTotals memory totals = harness.aggregatePremia(
            mixed,
            rawPremiaByLeg,
            availablePremiumByLeg,
            false,
            false
        );

        assertEq(totals.shortToken0, 0);
        assertEq(totals.shortToken1, 0);
        assertEq(totals.longToken0, 9);
        assertEq(totals.longToken1, 6);
        assertEq(totals.netToken0, -9);
        assertEq(totals.netToken1, -6);
    }

    function test_aggregatePremia_mixedLegNettingDiffersBetweenPendingAndAvailableShortCredit()
        external
        view
    {
        TokenId mixed = TokenId.wrap(0)
            .addLeg(0, 1, 0, 0, 0, 0, 0, 4)
            .addLeg(1, 1, 1, 1, 1, 1, 20, 3);

        PremiumExerciseSemanticsHarness.SignedAmountPair[4] memory rawPremiaByLeg;
        rawPremiaByLeg[0] = PremiumExerciseSemanticsHarness.SignedAmountPair(17, 10);
        rawPremiaByLeg[1] = PremiumExerciseSemanticsHarness.SignedAmountPair(11, 4);

        PremiumExerciseSemanticsHarness.UnsignedAmountPair[4] memory availablePremiumByLeg;
        availablePremiumByLeg[0] = PremiumExerciseSemanticsHarness.UnsignedAmountPair(6, 2);

        PremiumExerciseSemanticsHarness.PremiumTotals memory pendingTotals = harness.aggregatePremia(
            mixed,
            rawPremiaByLeg,
            availablePremiumByLeg,
            true,
            true
        );
        PremiumExerciseSemanticsHarness.PremiumTotals memory settledTotals = harness.aggregatePremia(
            mixed,
            rawPremiaByLeg,
            availablePremiumByLeg,
            true,
            false
        );

        assertEq(pendingTotals.netToken0, 6);
        assertEq(pendingTotals.netToken1, 6);
        assertEq(settledTotals.netToken0, -5);
        assertEq(settledTotals.netToken1, -2);
    }

    function test_aggregatePremia_multipleShortLegsAccumulateOnlyWhenCollateralized()
        external
        view
    {
        TokenId shortComplex = TokenId.wrap(0)
            .addLeg(0, 1, 0, 0, 0, 0, 0, 4)
            .addLeg(1, 1, 1, 0, 1, 1, 20, 3)
            .addLeg(2, 1, 0, 1, 0, 2, -10, 2);

        PremiumExerciseSemanticsHarness.SignedAmountPair[4] memory rawPremiaByLeg;
        rawPremiaByLeg[0] = PremiumExerciseSemanticsHarness.SignedAmountPair(5, 2);
        rawPremiaByLeg[1] = PremiumExerciseSemanticsHarness.SignedAmountPair(8, 7);
        rawPremiaByLeg[2] = PremiumExerciseSemanticsHarness.SignedAmountPair(4, 3);

        PremiumExerciseSemanticsHarness.PremiumTotals memory noShortCredit = harness
            .aggregatePremia(shortComplex, rawPremiaByLeg, _emptyAvailablePremium(), false, true);
        PremiumExerciseSemanticsHarness.PremiumTotals memory withShortCredit = harness
            .aggregatePremia(shortComplex, rawPremiaByLeg, _emptyAvailablePremium(), true, true);

        assertEq(noShortCredit.shortToken0, 0);
        assertEq(noShortCredit.shortToken1, 0);
        assertEq(noShortCredit.longToken0, 4);
        assertEq(noShortCredit.longToken1, 3);
        assertEq(noShortCredit.netToken0, -4);
        assertEq(noShortCredit.netToken1, -3);

        assertEq(withShortCredit.shortToken0, 13);
        assertEq(withShortCredit.shortToken1, 9);
        assertEq(withShortCredit.longToken0, 4);
        assertEq(withShortCredit.longToken1, 3);
        assertEq(withShortCredit.netToken0, 9);
        assertEq(withShortCredit.netToken1, 6);
    }

    function test_aggregatePremia_availableShortCreditCanFlipNetAgainstTheoreticalView()
        external
        view
    {
        TokenId mixed = TokenId.wrap(0)
            .addLeg(0, 1, 0, 0, 0, 0, 0, 4)
            .addLeg(1, 1, 1, 0, 1, 1, 20, 3)
            .addLeg(2, 1, 0, 1, 0, 2, -10, 5);

        PremiumExerciseSemanticsHarness.SignedAmountPair[4] memory rawPremiaByLeg;
        rawPremiaByLeg[0] = PremiumExerciseSemanticsHarness.SignedAmountPair(9, 4);
        rawPremiaByLeg[1] = PremiumExerciseSemanticsHarness.SignedAmountPair(6, 5);
        rawPremiaByLeg[2] = PremiumExerciseSemanticsHarness.SignedAmountPair(10, 8);

        PremiumExerciseSemanticsHarness.UnsignedAmountPair[4] memory availablePremiumByLeg;
        availablePremiumByLeg[0] = PremiumExerciseSemanticsHarness.UnsignedAmountPair(2, 1);
        availablePremiumByLeg[1] = PremiumExerciseSemanticsHarness.UnsignedAmountPair(1, 1);

        PremiumExerciseSemanticsHarness.PremiumTotals memory theoretical = harness.aggregatePremia(
            mixed,
            rawPremiaByLeg,
            availablePremiumByLeg,
            true,
            true
        );
        PremiumExerciseSemanticsHarness.PremiumTotals memory realizable = harness.aggregatePremia(
            mixed,
            rawPremiaByLeg,
            availablePremiumByLeg,
            true,
            false
        );

        assertEq(theoretical.netToken0, 5);
        assertEq(theoretical.netToken1, 1);
        assertEq(realizable.netToken0, -7);
        assertEq(realizable.netToken1, -6);
    }

    function test_aggregatePremia_zeroWidthLegIsIgnoredEvenIfMarkedLong() external view {
        TokenId zeroWidthLong = TokenId.wrap(0).addLeg(0, 1, 0, 1, 0, 0, 0, 0);

        PremiumExerciseSemanticsHarness.SignedAmountPair[4] memory rawPremiaByLeg;
        rawPremiaByLeg[0] = PremiumExerciseSemanticsHarness.SignedAmountPair(20, 20);

        PremiumExerciseSemanticsHarness.PremiumTotals memory totals = harness.aggregatePremia(
            zeroWidthLong,
            rawPremiaByLeg,
            _emptyAvailablePremium(),
            true,
            true
        );

        assertEq(totals.shortToken0, 0);
        assertEq(totals.shortToken1, 0);
        assertEq(totals.longToken0, 0);
        assertEq(totals.longToken1, 0);
        assertEq(totals.netToken0, 0);
        assertEq(totals.netToken1, 0);
    }

    function test_compareBurnAndForceExercise_zeroFeeMatchesBurnExactly() external view {
        PremiumExerciseSemanticsHarness.ExerciseComparison memory comparison = harness
            .compareBurnAndForceExercise(
                PremiumExerciseSemanticsHarness.SignedAmountPair(25, -9),
                PremiumExerciseSemanticsHarness.SignedAmountPair(0, 0)
            );

        assertEq(comparison.forceExerciseToken0, comparison.burnToken0);
        assertEq(comparison.forceExerciseToken1, comparison.burnToken1);
        assertEq(comparison.deltaToken0, 0);
        assertEq(comparison.deltaToken1, 0);
    }

    function test_compareBurnAndForceExercise_diffEqualsExplicitExerciseFee() external view {
        PremiumExerciseSemanticsHarness.ExerciseComparison memory comparison = harness
            .compareBurnAndForceExercise(
                PremiumExerciseSemanticsHarness.SignedAmountPair(-14, 22),
                PremiumExerciseSemanticsHarness.SignedAmountPair(3, -5)
            );

        assertEq(comparison.forceExerciseToken0, -11);
        assertEq(comparison.forceExerciseToken1, 17);
        assertEq(comparison.deltaToken0, 3);
        assertEq(comparison.deltaToken1, -5);
    }

    function test_compareBurnAndForceExercise_preservesBurnCoreBeforeFeeOverlay() external view {
        PremiumExerciseSemanticsHarness.ExerciseComparison memory comparison = harness
            .compareBurnAndForceExercise(
                PremiumExerciseSemanticsHarness.SignedAmountPair(100, -40),
                PremiumExerciseSemanticsHarness.SignedAmountPair(-7, 9)
            );

        assertEq(comparison.burnToken0, 100);
        assertEq(comparison.burnToken1, -40);
        assertEq(comparison.forceExerciseToken0 - comparison.deltaToken0, comparison.burnToken0);
        assertEq(comparison.forceExerciseToken1 - comparison.deltaToken1, comparison.burnToken1);
    }

    function test_compareBurnAndForceExercise_feeCanShiftOnlyOneTokenSide() external view {
        PremiumExerciseSemanticsHarness.ExerciseComparison memory comparison = harness
            .compareBurnAndForceExercise(
                PremiumExerciseSemanticsHarness.SignedAmountPair(-33, 18),
                PremiumExerciseSemanticsHarness.SignedAmountPair(0, 6)
            );

        assertEq(comparison.deltaToken0, 0);
        assertEq(comparison.deltaToken1, 6);
        assertEq(comparison.forceExerciseToken0, -33);
        assertEq(comparison.forceExerciseToken1, 24);
    }

    function test_compareBurnAndForceExercise_negativeFeeAdjustmentRemainsIsolated() external view {
        PremiumExerciseSemanticsHarness.ExerciseComparison memory comparison = harness
            .compareBurnAndForceExercise(
                PremiumExerciseSemanticsHarness.SignedAmountPair(8, 19),
                PremiumExerciseSemanticsHarness.SignedAmountPair(-2, 0)
            );

        assertEq(comparison.deltaToken0, -2);
        assertEq(comparison.deltaToken1, 0);
        assertEq(comparison.forceExerciseToken0, 6);
        assertEq(comparison.forceExerciseToken1, 19);
    }

    function _emptyAvailablePremium()
        internal
        pure
        returns (PremiumExerciseSemanticsHarness.UnsignedAmountPair[4] memory emptyPremium)
    {}
}
