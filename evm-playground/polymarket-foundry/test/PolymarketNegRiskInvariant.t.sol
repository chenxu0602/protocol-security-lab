// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from '@solady/src/tokens/ERC20.sol';
import { ERC1155 } from '@solady/src/tokens/ERC1155.sol';

import { PolymarketAuditBase, PolymarketArtifactDeployer } from './helpers/PolymarketAuditBase.sol';
import { USDC } from '@ctf-exchange-v2/src/test/dev/mocks/USDC.sol';
import {
    IConditionalTokens
} from '@ctf-exchange-v2/src/adapters/interfaces/IConditionalTokens.sol';
import { INegRiskAdapter } from '@ctf-exchange-v2/src/adapters/interfaces/INegRiskAdapter.sol';

contract PolymarketNegRiskInvariantTest is PolymarketAuditBase {
    USDC internal usdc;
    IConditionalTokens internal ctf;
    INegRiskAdapter internal adapter;
    address internal vault = address(0xA11CE);

    function setUp() public {
        _setUpActors();

        usdc = new USDC();
        ctf = _deployConditionalTokens();
        adapter = INegRiskAdapter(
            PolymarketArtifactDeployer.deployNegRiskAdapter(address(ctf), address(usdc), vault)
        );

        vm.label(vault, 'negRiskVault');
    }

    function test_convertPositionsPreservesValueWithExplicitFeeOnly() public {
        uint256 amount = 100_000_000;
        uint256 feeBips = 500;
        uint256 feeAmount = amount * feeBips / 10_000;
        uint256 amountOut = amount - feeAmount;

        bytes32 marketId = adapter.prepareMarket(feeBips, 'market');
        bytes32 question0 = adapter.prepareQuestion(marketId, 'q0');
        bytes32 question1 = adapter.prepareQuestion(marketId, 'q1');
        bytes32 question2 = adapter.prepareQuestion(marketId, 'q2');

        _splitQuestionFor(bob, adapter.getConditionId(question0), amount);
        _splitQuestionFor(bob, adapter.getConditionId(question1), amount);

        vm.prank(bob);
        ERC1155(address(ctf)).setApprovalForAll(address(adapter), true);

        uint256 no0 = adapter.getPositionId(question0, false);
        uint256 no1 = adapter.getPositionId(question1, false);
        uint256 no2 = adapter.getPositionId(question2, false);
        uint256 yes0 = adapter.getPositionId(question0, true);
        uint256 yes1 = adapter.getPositionId(question1, true);
        uint256 yes2 = adapter.getPositionId(question2, true);

        vm.prank(bob);
        adapter.convertPositions(marketId, 3, amount);

        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes0), amount);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes1), amount);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes2), amountOut);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, no0), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, no1), 0);
        assertEq(usdc.balanceOf(bob), amountOut);

        assertEq(ERC1155(address(ctf)).balanceOf(adapter.NO_TOKEN_BURN_ADDRESS(), no0), amount);
        assertEq(ERC1155(address(ctf)).balanceOf(adapter.NO_TOKEN_BURN_ADDRESS(), no1), amount);
        assertEq(ERC1155(address(ctf)).balanceOf(adapter.NO_TOKEN_BURN_ADDRESS(), no2), amount);

        assertEq(usdc.balanceOf(vault), feeAmount);
        assertEq(ERC1155(address(ctf)).balanceOf(vault, yes2), feeAmount);
    }

    function test_convertRequiresBoundedNonZeroIndexSet() public {
        bytes32 marketId = _prepareMarketWithQuestions(0, 3);

        vm.expectRevert(INegRiskAdapter.InvalidIndexSet.selector);
        vm.prank(bob);
        adapter.convertPositions(marketId, 0, 0);

        vm.expectRevert(INegRiskAdapter.InvalidIndexSet.selector);
        vm.prank(bob);
        adapter.convertPositions(marketId, 8, 0);
    }

    function test_convertRequiresAtLeastTwoQuestions() public {
        bytes32 marketId = _prepareMarketWithQuestions(0, 1);

        vm.expectRevert(INegRiskAdapter.NoConvertiblePositions.selector);
        vm.prank(bob);
        adapter.convertPositions(marketId, 1, 1);
    }

    function test_questionRegistryIsAppendOnlyForExistingQuestions() public {
        bytes32 marketId = adapter.prepareMarket(250, 'market');
        bytes32 question0 = adapter.prepareQuestion(marketId, 'q0');
        bytes32 question1 = adapter.prepareQuestion(marketId, 'q1');

        bytes32 condition0Before = adapter.getConditionId(question0);
        bytes32 condition1Before = adapter.getConditionId(question1);

        _splitQuestionFor(bob, condition0Before, 25_000_000);

        bytes32 question2 = adapter.prepareQuestion(marketId, 'q2');

        assertEq(adapter.getQuestionCount(marketId), 3);
        assertEq(adapter.getConditionId(question0), condition0Before);
        assertEq(adapter.getConditionId(question1), condition1Before);
        assertTrue(adapter.getConditionId(question2) != bytes32(0));
    }

    function test_reportOutcomeUsesBinaryNormalizedPayoutVector() public {
        bytes32 marketId = adapter.prepareMarket(0, 'market');
        bytes32 questionId = adapter.prepareQuestion(marketId, 'q0');
        bytes32 resolvedConditionId = adapter.getConditionId(questionId);

        adapter.reportOutcome(questionId, true);

        assertTrue(adapter.getDetermined(marketId));
        assertEq(adapter.getResult(marketId), 0);
        assertEq(ctf.payoutDenominator(resolvedConditionId), 1);
        assertEq(ctf.payoutNumerators(resolvedConditionId, 0), 1);
        assertEq(ctf.payoutNumerators(resolvedConditionId, 1), 0);
        assertEq(
            ctf.payoutNumerators(resolvedConditionId, 0)
                + ctf.payoutNumerators(resolvedConditionId, 1),
            1
        );
    }

    function test_marketGrowthDoesNotRebindExistingQuestionIdsOrConditionIds() public {
        uint256 amount = 25_000_000;
        bytes32 marketId = adapter.prepareMarket(0, 'market');
        bytes32 question0 = adapter.prepareQuestion(marketId, 'q0');
        bytes32 question1 = adapter.prepareQuestion(marketId, 'q1');

        bytes32 condition0Before = adapter.getConditionId(question0);
        bytes32 condition1Before = adapter.getConditionId(question1);
        uint256 yes0Before = adapter.getPositionId(question0, true);
        uint256 no0Before = adapter.getPositionId(question0, false);
        uint256 yes1Before = adapter.getPositionId(question1, true);
        uint256 no1Before = adapter.getPositionId(question1, false);

        _splitQuestionFor(bob, condition0Before, amount);

        bytes32 question2 = adapter.prepareQuestion(marketId, 'q2');
        bytes32 question3 = adapter.prepareQuestion(marketId, 'q3');

        assertEq(adapter.getQuestionCount(marketId), 4);
        assertEq(adapter.getConditionId(question0), condition0Before);
        assertEq(adapter.getConditionId(question1), condition1Before);
        assertEq(adapter.getPositionId(question0, true), yes0Before);
        assertEq(adapter.getPositionId(question0, false), no0Before);
        assertEq(adapter.getPositionId(question1, true), yes1Before);
        assertEq(adapter.getPositionId(question1, false), no1Before);
        assertTrue(adapter.getConditionId(question2) != bytes32(0));
        assertTrue(adapter.getConditionId(question3) != bytes32(0));

        adapter.reportOutcome(question0, true);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(bob);
        ERC1155(address(ctf)).setApprovalForAll(address(adapter), true);

        vm.prank(bob);
        adapter.redeemPositions(condition0Before, amounts);

        assertEq(usdc.balanceOf(bob), amount);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes0Before), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, no0Before), 0);
    }

    function _prepareMarketWithQuestions(uint256 feeBips, uint256 questionCount)
        internal
        returns (bytes32 marketId)
    {
        marketId = adapter.prepareMarket(feeBips, 'market');
        for (uint256 i; i < questionCount; ++i) {
            adapter.prepareQuestion(marketId, abi.encodePacked('q', vm.toString(i)));
        }
    }

    function _splitQuestionFor(address user, bytes32 conditionId, uint256 amount) internal {
        usdc.mint(user, amount);

        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        adapter.splitPosition(conditionId, amount);
        vm.stopPrank();
    }
}
