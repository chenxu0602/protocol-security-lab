// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from '@solady/src/tokens/ERC20.sol';
import { ERC1155 } from '@solady/src/tokens/ERC1155.sol';

import { PolymarketAuditBase } from './helpers/PolymarketAuditBase.sol';
import {
    Collateral,
    CollateralSetup,
    CollateralToken,
    USDCe
} from '@ctf-exchange-v2/src/test/dev/CollateralSetup.sol';
import { CTFHelpers } from '@ctf-exchange-v2/src/adapters/libraries/CTFHelpers.sol';
import { CtfCollateralAdapter } from '@ctf-exchange-v2/src/adapters/CtfCollateralAdapter.sol';
import { CollateralErrors } from '@ctf-exchange-v2/src/collateral/abstract/CollateralErrors.sol';
import {
    IConditionalTokens
} from '@ctf-exchange-v2/src/adapters/interfaces/IConditionalTokens.sol';

contract RejectingSplitCaller {
    function approveAndSplit(
        address collateralToken,
        address adapter,
        bytes32 conditionId,
        uint256 amount
    ) external {
        ERC20(collateralToken).approve(adapter, amount);
        CtfCollateralAdapter(adapter)
            .splitPosition(address(0), bytes32(0), conditionId, new uint256[](0), amount);
    }
}

contract PolymarketCtfCollateralAdapterInvariantTest is PolymarketAuditBase {
    Collateral internal collateral;
    USDCe internal usdce;
    IConditionalTokens internal ctf;
    CtfCollateralAdapter internal adapter;
    bytes32 internal questionId = keccak256('polymarket-adapter-question');
    bytes32 internal conditionId;
    uint256 internal yes;
    uint256 internal no;

    function setUp() public {
        _setUpActors();

        collateral = CollateralSetup._deploy(admin);
        usdce = collateral.usdce;
        ctf = _deployConditionalTokens();
        conditionId = _prepareCondition(ctf, admin, questionId);

        adapter = new CtfCollateralAdapter(
            admin, admin, address(ctf), address(collateral.token), address(usdce)
        );

        vm.prank(admin);
        collateral.token.addWrapper(address(adapter));

        uint256[] memory positionIds = CTFHelpers.positionIds(address(usdce), conditionId);
        yes = positionIds[0];
        no = positionIds[1];
    }

    function test_positionIdsMatchCanonicalConditionalTokensIds() public view {
        assertEq(yes, _positionId(ctf, address(usdce), conditionId, 1));
        assertEq(no, _positionId(ctf, address(usdce), conditionId, 2));
    }

    function test_splitPositionConservesCollateralIntoBinaryPositions() public {
        uint256 amount = 90_000_000;

        _wrapFor(bob, amount);

        vm.prank(bob);
        collateral.token.approve(address(adapter), amount);

        vm.prank(bob);
        adapter.splitPosition(address(0), bytes32(0), conditionId, new uint256[](0), amount);

        assertEq(collateral.token.balanceOf(bob), 0);
        assertEq(usdce.balanceOf(collateral.vault), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes), amount);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, no), amount);
        assertEq(usdce.balanceOf(address(adapter)), 0);
    }

    function test_mergePositionsConservesYesAndNoBackIntoCollateral() public {
        uint256 amount = 55_000_000;

        _splitFor(bob, amount);

        vm.prank(bob);
        ERC1155(address(ctf)).setApprovalForAll(address(adapter), true);

        vm.prank(bob);
        adapter.mergePositions(address(0), bytes32(0), conditionId, new uint256[](0), amount);

        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, no), 0);
        assertEq(collateral.token.balanceOf(bob), amount);
        assertEq(usdce.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.totalSupply(), amount);
    }

    function test_redeemPositionsIsPermissionlessForWinningHolder() public {
        uint256 amount = 41_000_000;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        _splitFor(bob, amount);

        vm.prank(bob);
        ERC1155(address(ctf)).safeTransferFrom(bob, carla, yes, amount, '');

        vm.prank(admin);
        ctf.reportPayouts(questionId, payouts);

        vm.prank(carla);
        ERC1155(address(ctf)).setApprovalForAll(address(adapter), true);

        vm.prank(carla);
        adapter.redeemPositions(address(0), bytes32(0), conditionId, new uint256[](0));

        assertEq(ERC1155(address(ctf)).balanceOf(carla, yes), 0);
        assertEq(collateral.token.balanceOf(carla), amount);
        assertEq(collateral.token.totalSupply(), amount);
        assertEq(usdce.balanceOf(address(adapter)), 0);
    }

    function test_redeemPositionsRevertsBeforeResolution() public {
        uint256 amount = 29_000_000;

        _splitFor(bob, amount);

        vm.prank(bob);
        ERC1155(address(ctf)).setApprovalForAll(address(adapter), true);

        vm.expectRevert();
        vm.prank(bob);
        adapter.redeemPositions(address(0), bytes32(0), conditionId, new uint256[](0));

        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes), amount);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, no), amount);
        assertEq(collateral.token.balanceOf(bob), 0);
        assertEq(usdce.balanceOf(address(adapter)), 0);
    }

    function test_binaryPayoutNormalizationCapsAggregateRedemption() public {
        uint256 amount = 47_000_000;
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        _splitFor(bob, amount);

        vm.startPrank(bob);
        ERC1155(address(ctf)).safeTransferFrom(bob, carla, yes, amount, '');
        ERC1155(address(ctf)).safeTransferFrom(bob, dylan, no, amount, '');
        vm.stopPrank();

        vm.prank(admin);
        ctf.reportPayouts(questionId, payouts);

        assertEq(ctf.payoutDenominator(conditionId), 1);
        assertEq(ctf.payoutNumerators(conditionId, 0), 1);
        assertEq(ctf.payoutNumerators(conditionId, 1), 0);
        assertEq(ctf.payoutNumerators(conditionId, 0) + ctf.payoutNumerators(conditionId, 1), 1);

        vm.prank(carla);
        ERC1155(address(ctf)).setApprovalForAll(address(adapter), true);
        vm.prank(dylan);
        ERC1155(address(ctf)).setApprovalForAll(address(adapter), true);

        vm.prank(carla);
        adapter.redeemPositions(address(0), bytes32(0), conditionId, new uint256[](0));

        vm.prank(dylan);
        adapter.redeemPositions(address(0), bytes32(0), conditionId, new uint256[](0));

        uint256 totalRedeemed =
            collateral.token.balanceOf(carla) + collateral.token.balanceOf(dylan);
        assertEq(totalRedeemed, amount);
        assertEq(collateral.token.balanceOf(carla), amount);
        assertEq(collateral.token.balanceOf(dylan), 0);

        vm.prank(carla);
        adapter.redeemPositions(address(0), bytes32(0), conditionId, new uint256[](0));

        assertEq(collateral.token.balanceOf(carla) + collateral.token.balanceOf(dylan), amount);
        assertEq(usdce.balanceOf(address(adapter)), 0);
    }

    function test_multiOutcomePayoutNormalizationPreservesBacking() public {
        bytes32 multiQuestionId = keccak256('polymarket-multi-outcome-question');
        bytes32 multiConditionId = ctf.getConditionId(admin, multiQuestionId, 3);
        uint256 amount = 60_000_000;
        uint256[] memory partition = new uint256[](3);
        uint256[] memory payouts = new uint256[](3);
        uint256[] memory outcome0Set = new uint256[](1);
        uint256[] memory outcome1Set = new uint256[](1);
        uint256[] memory outcome2Set = new uint256[](1);

        partition[0] = 1;
        partition[1] = 2;
        partition[2] = 4;

        payouts[0] = 1;
        payouts[1] = 2;
        payouts[2] = 3;

        outcome0Set[0] = 1;
        outcome1Set[0] = 2;
        outcome2Set[0] = 4;

        ctf.prepareCondition(admin, multiQuestionId, 3);

        usdce.mint(bob, amount);

        vm.startPrank(bob);
        usdce.approve(address(ctf), amount);
        ctf.splitPosition(address(usdce), bytes32(0), multiConditionId, partition, amount);
        vm.stopPrank();

        uint256 outcome0 = _positionId(ctf, address(usdce), multiConditionId, 1);
        uint256 outcome1 = _positionId(ctf, address(usdce), multiConditionId, 2);

        vm.startPrank(bob);
        ERC1155(address(ctf)).safeTransferFrom(bob, carla, outcome0, amount, '');
        ERC1155(address(ctf)).safeTransferFrom(bob, dylan, outcome1, amount, '');
        vm.stopPrank();

        vm.prank(admin);
        ctf.reportPayouts(multiQuestionId, payouts);

        assertEq(ctf.payoutDenominator(multiConditionId), 6);
        assertEq(
            ctf.payoutNumerators(multiConditionId, 0) + ctf.payoutNumerators(multiConditionId, 1)
                + ctf.payoutNumerators(multiConditionId, 2),
            6
        );

        vm.prank(carla);
        ctf.redeemPositions(address(usdce), bytes32(0), multiConditionId, outcome0Set);

        vm.prank(dylan);
        ctf.redeemPositions(address(usdce), bytes32(0), multiConditionId, outcome1Set);

        vm.prank(bob);
        ctf.redeemPositions(address(usdce), bytes32(0), multiConditionId, outcome2Set);

        assertEq(usdce.balanceOf(carla), 10_000_000);
        assertEq(usdce.balanceOf(dylan), 20_000_000);
        assertEq(usdce.balanceOf(bob), 30_000_000);
        assertEq(usdce.balanceOf(carla) + usdce.balanceOf(dylan) + usdce.balanceOf(bob), amount);

        vm.prank(carla);
        ctf.redeemPositions(address(usdce), bytes32(0), multiConditionId, outcome0Set);
        vm.prank(dylan);
        ctf.redeemPositions(address(usdce), bytes32(0), multiConditionId, outcome1Set);
        vm.prank(bob);
        ctf.redeemPositions(address(usdce), bytes32(0), multiConditionId, outcome2Set);

        assertEq(usdce.balanceOf(carla) + usdce.balanceOf(dylan) + usdce.balanceOf(bob), amount);
    }

    function test_pauseBlocksSplitButCannotRerouteAssets() public {
        uint256 amount = 30_000_000;

        _wrapFor(bob, amount);

        vm.prank(admin);
        adapter.pause(address(usdce));

        vm.prank(bob);
        collateral.token.approve(address(adapter), amount);

        vm.prank(bob);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        adapter.splitPosition(address(0), bytes32(0), conditionId, new uint256[](0), amount);

        assertEq(collateral.token.balanceOf(bob), amount);
        assertEq(usdce.balanceOf(collateral.vault), amount);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, no), 0);
    }

    function test_splitRollsBackWhenRecipientRejectsErc1155() public {
        uint256 amount = 20_000_000;
        RejectingSplitCaller caller = new RejectingSplitCaller();

        usdce.mint(bob, amount);

        vm.startPrank(bob);
        usdce.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdce), address(caller), amount);
        vm.stopPrank();

        vm.expectRevert();
        caller.approveAndSplit(address(collateral.token), address(adapter), conditionId, amount);

        assertEq(collateral.token.balanceOf(address(caller)), amount);
        assertEq(usdce.balanceOf(collateral.vault), amount);
        assertEq(usdce.balanceOf(address(adapter)), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(address(caller), yes), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(address(caller), no), 0);
    }

    function _wrapFor(address user, uint256 amount) internal {
        usdce.mint(user, amount);

        vm.startPrank(user);
        usdce.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdce), user, amount);
        vm.stopPrank();
    }

    function _splitFor(address user, uint256 amount) internal {
        _wrapFor(user, amount);

        vm.prank(user);
        collateral.token.approve(address(adapter), amount);

        vm.prank(user);
        adapter.splitPosition(address(0), bytes32(0), conditionId, new uint256[](0), amount);
    }
}
