// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {Errors} from 'panoptic-v2-core/contracts/libraries/Errors.sol';
import {EfficientHash} from 'panoptic-v2-core/contracts/libraries/EfficientHash.sol';
import {PanopticMath} from 'panoptic-v2-core/contracts/libraries/PanopticMath.sol';
import {TokenId} from 'panoptic-v2-core/contracts/types/TokenId.sol';

contract DispatchSemanticsHarness {
    uint64 internal immutable expectedPoolId;
    mapping(address => uint256) internal positionsHash;

    uint8 internal constant BRANCH_SETTLE = 1;
    uint8 internal constant BRANCH_FORCE_EXERCISE = 2;
    uint8 internal constant BRANCH_LIQUIDATION = 3;

    constructor(uint64 _expectedPoolId) {
        expectedPoolId = _expectedPoolId;
    }

    function setPositionsHash(address account, uint256 hash) external {
        positionsHash[account] = hash;
    }

    function computeHash(TokenId[] memory positionIdList) external pure returns (uint256 fingerprint) {
        for (uint256 i = 0; i < positionIdList.length; ++i) {
            fingerprint = PanopticMath.updatePositionsHash(fingerprint, positionIdList[i], true);
        }
    }

    function dispatchDecision(
        address account,
        TokenId[] calldata positionIdListTo,
        TokenId[] calldata positionIdListToFinal,
        uint256 solvent,
        uint256 numberOfTicks,
        int24 currentTick,
        int24 twapTick,
        uint24 maxTwapDeltaDispatch
    ) external view returns (uint8 branch) {
        _validatePositionList(account, positionIdListTo);

        uint256 toLength = positionIdListTo.length;
        uint256 finalLength = positionIdListToFinal.length;

        if (solvent == numberOfTicks) {
            if (_abs(currentTick - twapTick) > maxTwapDeltaDispatch) revert Errors.StaleOracle();

            TokenId tokenId = positionIdListTo[toLength - 1];

            if (toLength == finalLength) {
                bytes32 toHash = EfficientHash.efficientKeccak256(abi.encodePacked(positionIdListTo));
                bytes32 finalHash = EfficientHash.efficientKeccak256(
                    abi.encodePacked(positionIdListToFinal)
                );
                if (toHash != finalHash) revert Errors.InputListFail();
                return BRANCH_SETTLE;
            }

            if (toLength == finalLength + 1) {
                if (tokenId.countLongs() == 0 || tokenId.validateIsExercisable() == 0) {
                    revert Errors.NoLegsExercisable();
                }
                return BRANCH_FORCE_EXERCISE;
            }

            if (finalLength == 0) revert Errors.NotMarginCalled();
            revert Errors.InputListFail();
        }

        if (solvent == 0) {
            if (toLength == finalLength) revert Errors.AccountInsolvent(solvent, 4);
            if (finalLength != 0) revert Errors.InputListFail();
            return BRANCH_LIQUIDATION;
        }

        revert Errors.NotMarginCalled();
    }

    function _validatePositionList(address account, TokenId[] calldata positionIdList) internal view {
        uint256 fingerprintIncomingList;

        if (!PanopticMath.hasNoDuplicateTokenIds(positionIdList)) revert Errors.DuplicateTokenId();

        for (uint256 i = 0; i < positionIdList.length; ++i) {
            TokenId tokenId = positionIdList[i];
            if (tokenId.poolId() != expectedPoolId) revert Errors.WrongPoolId();
            fingerprintIncomingList = PanopticMath.updatePositionsHash(
                fingerprintIncomingList,
                tokenId,
                true
            );
        }

        if (fingerprintIncomingList != positionsHash[account]) revert Errors.InputListFail();
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }
}

contract PanopticDispatchSemanticsTest is Test {
    DispatchSemanticsHarness internal harness;

    address internal account = address(0xA11CE);
    uint64 internal constant POOL_ID = uint64(0x1234);
    uint8 internal constant BRANCH_SETTLE = 1;
    uint8 internal constant BRANCH_FORCE_EXERCISE = 2;
    uint8 internal constant BRANCH_LIQUIDATION = 3;

    function setUp() public {
        harness = new DispatchSemanticsHarness(POOL_ID);
    }

    function test_dispatchDecision_rejectsDuplicateTokenIds() external {
        TokenId position = _token({isLong: false, width: 4});
        TokenId[] memory list = new TokenId[](2);
        list[0] = position;
        list[1] = position;

        harness.setPositionsHash(account, 0);

        vm.expectRevert(Errors.DuplicateTokenId.selector);
        harness.dispatchDecision(account, list, list, 4, 4, 0, 0, 100);
    }

    function test_dispatchDecision_rejectsWrongPoolId() external {
        TokenId[] memory list = new TokenId[](1);
        list[0] = TokenId.wrap(0x9999).addLeg(0, 1, 0, 0, 0, 0, 0, 4);
        harness.setPositionsHash(account, 0);

        vm.expectRevert(Errors.WrongPoolId.selector);
        harness.dispatchDecision(account, list, list, 4, 4, 0, 0, 100);
    }

    function test_dispatchDecision_rejectsPositionsHashMismatch() external {
        TokenId[] memory list = _singleton(_token({isLong: false, width: 4}));
        harness.setPositionsHash(account, 123);

        vm.expectRevert(Errors.InputListFail.selector);
        harness.dispatchDecision(account, list, list, 4, 4, 0, 0, 100);
    }

    function test_dispatchDecision_routesToSettleWhenListsMatchExactly() external {
        TokenId[] memory list = _singleton(_token({isLong: false, width: 4}));
        harness.setPositionsHash(account, harness.computeHash(list));

        uint8 branch = harness.dispatchDecision(account, list, list, 4, 4, 10, 5, 100);
        assertEq(branch, BRANCH_SETTLE);
    }

    function test_dispatchDecision_settleRequiresExactListOrder() external {
        TokenId[] memory to = new TokenId[](2);
        TokenId[] memory finalList = new TokenId[](2);

        to[0] = _token({isLong: false, width: 4});
        to[1] = _tokenWithStrike({isLong: true, width: 2, strike: 50});
        finalList[0] = to[1];
        finalList[1] = to[0];

        harness.setPositionsHash(account, harness.computeHash(to));

        vm.expectRevert(Errors.InputListFail.selector);
        harness.dispatchDecision(account, to, finalList, 4, 4, 10, 5, 100);
    }

    function test_dispatchDecision_routesToForceExerciseOnOneItemRemoval() external {
        TokenId[] memory to = new TokenId[](2);
        TokenId[] memory finalList = new TokenId[](1);

        to[0] = _token({isLong: false, width: 4});
        to[1] = _token({isLong: true, width: 3});
        finalList[0] = to[0];

        harness.setPositionsHash(account, harness.computeHash(to));

        uint8 branch = harness.dispatchDecision(account, to, finalList, 4, 4, 10, 5, 100);
        assertEq(branch, BRANCH_FORCE_EXERCISE);
    }

    function test_dispatchDecision_forceExerciseRejectsShortOnlyLastToken() external {
        TokenId[] memory to = new TokenId[](2);
        TokenId[] memory finalList = new TokenId[](1);

        to[0] = _token({isLong: true, width: 2});
        to[1] = _token({isLong: false, width: 4});
        finalList[0] = to[0];

        harness.setPositionsHash(account, harness.computeHash(to));

        vm.expectRevert(Errors.NoLegsExercisable.selector);
        harness.dispatchDecision(account, to, finalList, 4, 4, 10, 5, 100);
    }

    function test_dispatchDecision_forceExerciseRejectsLongLoanLastToken() external {
        TokenId[] memory to = new TokenId[](2);
        TokenId[] memory finalList = new TokenId[](1);

        to[0] = _token({isLong: false, width: 4});
        to[1] = _token({isLong: true, width: 0});
        finalList[0] = to[0];

        harness.setPositionsHash(account, harness.computeHash(to));

        vm.expectRevert(Errors.NoLegsExercisable.selector);
        harness.dispatchDecision(account, to, finalList, 4, 4, 10, 5, 100);
    }

    function test_dispatchDecision_solventAccountCannotUseLiquidationShape() external {
        TokenId[] memory list = new TokenId[](2);
        TokenId[] memory empty;

        list[0] = _token({isLong: false, width: 4});
        list[1] = _token({isLong: true, width: 2});
        harness.setPositionsHash(account, harness.computeHash(list));

        vm.expectRevert(Errors.NotMarginCalled.selector);
        harness.dispatchDecision(account, list, empty, 4, 4, 10, 5, 100);
    }

    function test_dispatchDecision_singleSolventLongWithEmptyFinalRoutesToForceExercise() external {
        TokenId[] memory list = _singleton(_token({isLong: true, width: 2}));
        TokenId[] memory empty;

        harness.setPositionsHash(account, harness.computeHash(list));

        uint8 branch = harness.dispatchDecision(account, list, empty, 4, 4, 10, 5, 100);
        assertEq(branch, BRANCH_FORCE_EXERCISE);
    }

    function test_dispatchDecision_solventInvalidLengthShapeRevertsInputListFail() external {
        TokenId[] memory to = new TokenId[](3);
        TokenId[] memory finalList = new TokenId[](1);

        to[0] = _token({isLong: false, width: 4});
        to[1] = _tokenWithStrike({isLong: false, width: 4, strike: 10});
        to[2] = _token({isLong: true, width: 2});
        finalList[0] = to[0];

        harness.setPositionsHash(account, harness.computeHash(to));

        vm.expectRevert(Errors.InputListFail.selector);
        harness.dispatchDecision(account, to, finalList, 4, 4, 10, 5, 100);
    }

    function test_dispatchDecision_partialSolvencyRevertsNotMarginCalled() external {
        TokenId[] memory list = _singleton(_token({isLong: true, width: 2}));
        harness.setPositionsHash(account, harness.computeHash(list));

        vm.expectRevert(Errors.NotMarginCalled.selector);
        harness.dispatchDecision(account, list, list, 2, 4, 10, 5, 100);
    }

    function test_dispatchDecision_staleOracleRevertsBeforeSettle() external {
        TokenId[] memory list = _singleton(_token({isLong: true, width: 2}));
        harness.setPositionsHash(account, harness.computeHash(list));

        vm.expectRevert(Errors.StaleOracle.selector);
        harness.dispatchDecision(account, list, list, 4, 4, 500, 0, 100);
    }

    function test_dispatchDecision_insolventAccountRejectsSettleShape() external {
        TokenId[] memory list = _singleton(_token({isLong: false, width: 4}));
        harness.setPositionsHash(account, harness.computeHash(list));

        vm.expectRevert(abi.encodeWithSelector(Errors.AccountInsolvent.selector, 0, 4));
        harness.dispatchDecision(account, list, list, 0, 4, 10, 5, 100);
    }

    function test_dispatchDecision_insolventAccountRejectsNonEmptyFinalList() external {
        TokenId[] memory to = new TokenId[](2);
        TokenId[] memory finalList = new TokenId[](1);

        to[0] = _token({isLong: false, width: 4});
        to[1] = _token({isLong: true, width: 2});
        finalList[0] = to[0];

        harness.setPositionsHash(account, harness.computeHash(to));

        vm.expectRevert(Errors.InputListFail.selector);
        harness.dispatchDecision(account, to, finalList, 0, 4, 10, 5, 100);
    }

    function test_dispatchDecision_routesToLiquidationWhenFullyInsolventAndFinalEmpty() external {
        TokenId[] memory list = _singleton(_token({isLong: false, width: 4}));
        TokenId[] memory empty;

        harness.setPositionsHash(account, harness.computeHash(list));

        uint8 branch = harness.dispatchDecision(account, list, empty, 0, 4, 10, 5, 100);
        assertEq(branch, BRANCH_LIQUIDATION);
    }

    function _singleton(TokenId tokenId) internal pure returns (TokenId[] memory list) {
        list = new TokenId[](1);
        list[0] = tokenId;
    }

    function _token(bool isLong, int24 width) internal pure returns (TokenId) {
        return _tokenWithStrike(isLong, width, 0);
    }

    function _tokenWithStrike(
        bool isLong,
        int24 width,
        int24 strike
    ) internal pure returns (TokenId) {
        return TokenId.wrap(POOL_ID).addLeg(
            0,
            1,
            0,
            isLong ? 1 : 0,
            0,
            0,
            strike,
            width
        );
    }
}
