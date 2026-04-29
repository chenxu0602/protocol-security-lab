// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1155} from "@solady/src/tokens/ERC1155.sol";

import {PolymarketAuditBase} from "./helpers/PolymarketAuditBase.sol";
import {USDC} from "@ctf-exchange-v2/src/test/dev/mocks/USDC.sol";
import {CTFExchange} from "@ctf-exchange-v2/src/exchange/CTFExchange.sol";
import {IConditionalTokens} from "@ctf-exchange-v2/src/adapters/interfaces/IConditionalTokens.sol";
import {Order, OrderStatus, Side} from "@ctf-exchange-v2/src/exchange/libraries/Structs.sol";

contract PolymarketRoundingDriftCharacterizationTest is PolymarketAuditBase {
    function setUp() public {
        _setUpActors();
    }

    function test_roundingBiasDirection_isStableAcrossRefinementChain() public {
        uint256 makerAmount = 10_000_001;
        uint256 takerAmount = 7_000_000;

        uint256[] memory partitions = new uint256[](1);
        partitions[0] = makerAmount;

        uint256 previousSpent = type(uint256).max;
        uint256 previousReceived = type(uint256).max;
        bool sawStrictDrift;

        for (uint256 depth; depth < 7; ++depth) {
            (uint256 spent, uint256 received, uint256 remaining) =
                _runComplementaryScenario(partitions, makerAmount, takerAmount, depth);

            emit log_named_uint("depth", depth);
            emit log_named_uint("fill_count", partitions.length);
            emit log_named_uint("taker_spent", spent);
            emit log_named_uint("maker_received", received);
            emit log_named_uint("remaining", remaining);

            if (depth > 0) {
                assertLe(
                    spent,
                    previousSpent,
                    "refining the fill schedule should not increase taker spend"
                );
                assertLe(
                    received,
                    previousReceived,
                    "refining the fill schedule should not increase maker receive"
                );
                if (spent < previousSpent || received < previousReceived) {
                    sawStrictDrift = true;
                }
            }

            previousSpent = spent;
            previousReceived = received;
            partitions = _refinePartitions(partitions);
        }

        assertTrue(sawStrictDrift, "expected at least one strict rounding drift step");
    }

    function test_roundingBiasAmplifiesUnderMicroFillRefinement() public {
        uint256 makerAmount = 10_000_001;
        uint256 takerAmount = 7_000_000;

        uint256[] memory coarse = new uint256[](1);
        coarse[0] = makerAmount;

        uint256[] memory refined = coarse;
        for (uint256 i; i < 7; ++i) {
            refined = _refinePartitions(refined);
        }

        (uint256 coarseSpent, uint256 coarseReceived, uint256 coarseRemaining) =
            _runComplementaryScenario(coarse, makerAmount, takerAmount, 100);
        (uint256 refinedSpent, uint256 refinedReceived, uint256 refinedRemaining) =
            _runComplementaryScenario(refined, makerAmount, takerAmount, 200);
        emit log_named_uint("coarse_fill_count", coarse.length);
        emit log_named_uint("refined_fill_count", refined.length);
        emit log_named_uint("coarse_taker_spent", coarseSpent);
        emit log_named_uint("refined_taker_spent", refinedSpent);
        emit log_named_uint("coarse_maker_received", coarseReceived);
        emit log_named_uint("refined_maker_received", refinedReceived);
        emit log_named_uint("coarse_remaining", coarseRemaining);
        emit log_named_uint("refined_remaining", refinedRemaining);

        assertGt(
            coarseSpent - refinedSpent,
            0,
            "expected positive taker-spend drift under deep refinement"
        );
        assertGt(
            coarseReceived - refinedReceived,
            0,
            "expected positive maker-receive drift under deep refinement"
        );
        assertGe(
            refinedRemaining,
            coarseRemaining,
            "refined schedule should not reduce leftover dust on the taker order"
        );
    }

    function _runComplementaryScenario(
        uint256[] memory makerFillAmounts,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 saltSuffix
    ) internal returns (uint256 takerSpent, uint256 makerReceived, uint256 remaining) {
        USDC localUsdc = new USDC();
        IConditionalTokens localCtf = _deployConditionalTokens();
        bytes32 localConditionId = _prepareCondition(
            localCtf,
            admin,
            keccak256(
                abi.encodePacked(
                    "rounding-drift-characterization",
                    makerFillAmounts.length,
                    saltSuffix
                )
            )
        );
        uint256 localYes = _positionId(localCtf, address(localUsdc), localConditionId, 1);
        CTFExchange localExchange =
            _deployExchange(address(localUsdc), address(localCtf), address(localUsdc), address(localCtf));

        localUsdc.mint(bob, takerAmount);
        vm.prank(bob);
        localUsdc.approve(address(localExchange), takerAmount);

        localUsdc.mint(admin, makerAmount);
        vm.startPrank(admin);
        localUsdc.approve(address(localCtf), makerAmount);
        localCtf.splitPosition(address(localUsdc), bytes32(0), localConditionId, _partition(), makerAmount);
        ERC1155(address(localCtf)).safeTransferFrom(admin, carla, localYes, makerAmount, "");
        vm.stopPrank();

        vm.prank(carla);
        ERC1155(address(localCtf)).setApprovalForAll(address(localExchange), true);

        Order memory takerOrder =
            _createAndSignOrder(localExchange, bobPK, localYes, takerAmount, makerAmount, Side.BUY);
        Order memory makerOrder =
            _createAndSignOrder(localExchange, carlaPK, localYes, makerAmount, takerAmount, Side.SELL);

        uint256 takerBefore = localUsdc.balanceOf(bob);
        uint256 makerBefore = localUsdc.balanceOf(carla);

        for (uint256 i; i < makerFillAmounts.length; ++i) {
            Order[] memory makers = new Order[](1);
            makers[0] = makerOrder;

            uint256[] memory makerFills = new uint256[](1);
            makerFills[0] = makerFillAmounts[i];

            uint256[] memory makerFees = new uint256[](1);
            makerFees[0] = 0;

            uint256 takerFill = makerFillAmounts[i] * takerAmount / makerAmount;

            vm.prank(admin);
            localExchange.matchOrders(localConditionId, takerOrder, makers, takerFill, makerFills, 0, makerFees);
        }

        takerSpent = takerBefore - localUsdc.balanceOf(bob);
        makerReceived = localUsdc.balanceOf(carla) - makerBefore;
        remaining = localExchange.getOrderStatus(localExchange.hashOrder(takerOrder)).remaining;
    }

    function _refinePartitions(uint256[] memory current)
        internal
        pure
        returns (uint256[] memory refined)
    {
        refined = new uint256[](current.length * 2);
        for (uint256 i; i < current.length; ++i) {
            uint256 left = current[i] / 2;
            uint256 right = current[i] - left;
            refined[2 * i] = left;
            refined[2 * i + 1] = right;
        }
    }

    function _partition() internal pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
    }

}
