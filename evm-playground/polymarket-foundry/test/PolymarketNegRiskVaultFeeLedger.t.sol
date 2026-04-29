// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC1155 } from '@solady/src/tokens/ERC1155.sol';

import { PolymarketAuditBase, PolymarketArtifactDeployer } from './helpers/PolymarketAuditBase.sol';
import { USDC } from '@ctf-exchange-v2/src/test/dev/mocks/USDC.sol';
import { IConditionalTokens } from '@ctf-exchange-v2/src/adapters/interfaces/IConditionalTokens.sol';
import { INegRiskAdapter } from '@ctf-exchange-v2/src/adapters/interfaces/INegRiskAdapter.sol';

contract PolymarketNegRiskVaultFeeLedgerTest is PolymarketAuditBase {
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
    }

    function test_vaultBalanceEqualsFeeLedger() public {
        uint256 feeBips = 500;
        uint256 amountA = 100_000_000;
        uint256 amountB = 40_000_000;
        uint256 expectedUsdcFees = amountA * feeBips / 10_000 + amountB * feeBips / 10_000;

        bytes32 marketId = adapter.prepareMarket(feeBips, 'market');
        bytes32 question0 = adapter.prepareQuestion(marketId, 'q0');
        bytes32 question1 = adapter.prepareQuestion(marketId, 'q1');
        bytes32 question2 = adapter.prepareQuestion(marketId, 'q2');

        _splitQuestionFor(bob, adapter.getConditionId(question0), amountA);
        _splitQuestionFor(bob, adapter.getConditionId(question1), amountA);

        vm.prank(bob);
        ERC1155(address(ctf)).setApprovalForAll(address(adapter), true);

        vm.prank(bob);
        adapter.convertPositions(marketId, 3, amountA);

        _splitQuestionFor(carla, adapter.getConditionId(question0), amountB);
        _splitQuestionFor(carla, adapter.getConditionId(question1), amountB);

        vm.prank(carla);
        ERC1155(address(ctf)).setApprovalForAll(address(adapter), true);

        vm.prank(carla);
        adapter.convertPositions(marketId, 3, amountB);

        uint256 yes2 = adapter.getPositionId(question2, true);

        assertEq(usdc.balanceOf(vault), expectedUsdcFees, 'vault usdc != accumulated fee ledger');
        assertEq(
            ERC1155(address(ctf)).balanceOf(vault, yes2),
            expectedUsdcFees,
            'vault erc1155 fee balance != accumulated fee ledger'
        );
    }

    function _splitQuestionFor(address user, bytes32 conditionId, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(adapter), amount);
        adapter.splitPosition(conditionId, amount);
        vm.stopPrank();
    }
}
