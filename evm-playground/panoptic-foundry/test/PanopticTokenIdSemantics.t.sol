// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {TokenId} from 'panoptic-v2-core/contracts/types/TokenId.sol';

contract TokenIdExerciseHarness {
    function validate(TokenId tokenId) external pure returns (uint256) {
        return tokenId.validateIsExercisable();
    }

    function countLegs(TokenId tokenId) external pure returns (uint256) {
        return tokenId.countLegs();
    }

    function countLongs(TokenId tokenId) external pure returns (uint256) {
        return tokenId.countLongs();
    }
}

contract PanopticTokenIdSemanticsTest is Test {
    TokenIdExerciseHarness internal harness;

    function setUp() public {
        harness = new TokenIdExerciseHarness();
    }

    function test_validateIsExercisable_rejectsShortOnlyPosition() external view {
        TokenId shortOnly = TokenId.wrap(0).addLeg({
            legIndex: 0,
            _optionRatio: 1,
            _asset: 0,
            _isLong: 0,
            _tokenType: 0,
            _riskPartner: 0,
            _strike: 0,
            _width: 4
        });

        assertEq(harness.validate(shortOnly), 0);
    }

    function test_validateIsExercisable_rejectsLongLoanLeg() external view {
        TokenId longLoanLeg = TokenId.wrap(0).addLeg({
            legIndex: 0,
            _optionRatio: 1,
            _asset: 0,
            _isLong: 1,
            _tokenType: 0,
            _riskPartner: 0,
            _strike: 0,
            _width: 0
        });

        assertEq(harness.validate(longLoanLeg), 0);
    }

    function test_validateIsExercisable_onlyChecksStructure_notMoneyness() external view {
        TokenId structurallyExercisable = TokenId.wrap(0).addLeg({
            legIndex: 0,
            _optionRatio: 1,
            _asset: 0,
            _isLong: 1,
            _tokenType: 0,
            _riskPartner: 0,
            _strike: 887_200,
            _width: 2
        });

        assertEq(harness.validate(structurallyExercisable), 1);
    }

    function test_validateIsExercisable_acceptsMixedPositionWhenAnyLongLegHasWidth() external view {
        TokenId mixedPosition = TokenId.wrap(0)
            .addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 0,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: 0,
                _width: 4
            })
            .addLeg({
                legIndex: 1,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 1,
                _tokenType: 1,
                _riskPartner: 1,
                _strike: 120,
                _width: 6
            });

        assertEq(harness.validate(mixedPosition), 1);
    }

    function test_validateIsExercisable_rejectsEmptyTokenId() external view {
        assertEq(harness.validate(TokenId.wrap(0)), 0);
    }

    function test_validateIsExercisable_acceptsLaterLongLegWithoutEarlierLongLegs() external view {
        TokenId laterLong = TokenId.wrap(0)
            .addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 0,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: -50,
                _width: 8
            })
            .addLeg({
                legIndex: 1,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 1,
                _tokenType: 1,
                _riskPartner: 1,
                _strike: 887_000,
                _width: 1
            });

        assertEq(harness.validate(laterLong), 1);
    }

    function test_countLegs_tracksActiveLegsOnly() external view {
        TokenId twoLegs = TokenId.wrap(0)
            .addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 0,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: 0,
                _width: 4
            })
            .addLeg({
                legIndex: 1,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 1,
                _tokenType: 1,
                _riskPartner: 1,
                _strike: 40,
                _width: 3
            });

        assertEq(harness.countLegs(TokenId.wrap(0)), 0);
        assertEq(harness.countLegs(twoLegs), 2);
    }

    function test_countLongs_countsAcrossAllLegs() external view {
        TokenId threeLegs = TokenId.wrap(0)
            .addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 0,
                _isLong: 1,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: 0,
                _width: 2
            })
            .addLeg({
                legIndex: 1,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 0,
                _tokenType: 1,
                _riskPartner: 1,
                _strike: 20,
                _width: 4
            })
            .addLeg({
                legIndex: 2,
                _optionRatio: 1,
                _asset: 0,
                _isLong: 1,
                _tokenType: 0,
                _riskPartner: 2,
                _strike: -20,
                _width: 6
            });

        assertEq(harness.countLongs(threeLegs), 2);
    }
}
