// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC1155 } from "@solady/src/tokens/ERC1155.sol";

import { PolymarketAuditBase } from "./helpers/PolymarketAuditBase.sol";
import { USDC } from "@ctf-exchange-v2/src/test/dev/mocks/USDC.sol";
import { CTFExchange } from "@ctf-exchange-v2/src/exchange/CTFExchange.sol";
import { IConditionalTokens } from "@ctf-exchange-v2/src/adapters/interfaces/IConditionalTokens.sol";
import { Order, OrderStatus, Side } from "@ctf-exchange-v2/src/exchange/libraries/Structs.sol";

contract TaxedCollateralTokenReview {
    string public constant name = "Taxed USD";
    string public constant symbol = "tUSD";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    uint256 public immutable taxBps;
    address public immutable taxSink;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(uint256 taxBps_, address taxSink_) {
        taxBps = taxBps_;
        taxSink = taxSink_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        uint256 fee = amount * taxBps / 10_000;
        uint256 received = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += received;
        emit Transfer(from, to, received);
        if (fee > 0) {
            balanceOf[taxSink] += fee;
            emit Transfer(from, taxSink, fee);
        }
    }
}

contract PolymarketRoundingAndPreapprovalReviewTest is PolymarketAuditBase {
    USDC internal usdc;
    IConditionalTokens internal ctf;
    CTFExchange internal exchange;
    bytes32 internal conditionId;
    uint256 internal yes;

    function setUp() public {
        _setUpActors();

        usdc = new USDC();
        ctf = _deployConditionalTokens();
        conditionId = _prepareCondition(ctf, admin, keccak256("polymarket-rounding-review"));
        yes = _positionId(ctf, address(usdc), conditionId, 1);
        exchange = _deployExchange(address(usdc), address(ctf), address(usdc), address(ctf));
    }

    function test_singleFillVsPartitionedFill_differential() public {
        uint256[] memory singleFill = new uint256[](1);
        singleFill[0] = 10_000_001;

        uint256[] memory splitFills = new uint256[](11);
        for (uint256 i; i < 10; ++i) splitFills[i] = 1_000_000;
        splitFills[10] = 1;

        (uint256 singleSpent, uint256 singleMakerReceived, uint256 singleRemaining) =
            _runComplementaryScenario(singleFill, 10_000_001, 7_000_000);
        (uint256 splitSpent, uint256 splitMakerReceived, uint256 splitRemaining) =
            _runComplementaryScenario(splitFills, 10_000_001, 7_000_000);

        assertEq(singleRemaining, 0);
        assertEq(singleMakerReceived, 7_000_000);

        // This is intentionally a differential-behavior detector, not a safety proof.
        assertLt(splitSpent, singleSpent, "expected fill-schedule drift in taker spend");
        assertLt(splitMakerReceived, singleMakerReceived, "expected fill-schedule drift in maker receive");
        assertGt(splitRemaining, 0, "expected dust remainder from partitioned fills");
    }

    function test_makerOrderPermutationInvariance() public {
        (uint256 spentForward, uint256 receivedForward) = _runPermutationScenario(false);
        (uint256 spentReverse, uint256 receivedReverse) = _runPermutationScenario(true);

        assertEq(spentForward, spentReverse, "taker spend changed by maker ordering");
        assertEq(receivedForward, receivedReverse, "aggregate maker receive changed by maker ordering");
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
                _runComplementaryScenario(partitions, makerAmount, takerAmount);

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
            _runComplementaryScenario(coarse, makerAmount, takerAmount);
        (uint256 refinedSpent, uint256 refinedReceived, uint256 refinedRemaining) =
            _runComplementaryScenario(refined, makerAmount, takerAmount);

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
        assertGt(
            refinedRemaining,
            coarseRemaining,
            "refined schedule should not reduce leftover dust on the taker order"
        );
    }

    function test_partialFillInvalidate_noSignatureRetry() public {
        dealUsdcAndApprove(bob, 50_000_000);
        dealOutcomeTokensAndApprove(carla, yes, 100_000_000);

        Order memory takerOrder =
            _createAndSignOrder(exchange, bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder =
            _createAndSignOrder(exchange, carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        vm.prank(admin);
        exchange.preapproveOrder(takerOrder);
        takerOrder.signature = new bytes(0);

        Order[] memory makers = new Order[](1);
        makers[0] = makerOrder;

        uint256[] memory partialMakerFills = new uint256[](1);
        partialMakerFills[0] = 50_000_000;

        uint256[] memory retryMakerFills = new uint256[](1);
        retryMakerFills[0] = 1;

        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;

        vm.prank(admin);
        exchange.matchOrders(conditionId, takerOrder, makers, 25_000_000, partialMakerFills, 0, fees);

        bytes32 orderHash = exchange.hashOrder(takerOrder);

        vm.prank(admin);
        exchange.invalidatePreapprovedOrder(orderHash);

        vm.expectRevert();
        vm.prank(admin);
        exchange.matchOrders(conditionId, takerOrder, makers, 1, retryMakerFills, 0, fees);

        OrderStatus memory status = exchange.getOrderStatus(orderHash);
        assertFalse(status.filled);
        assertEq(status.remaining, 25_000_000);
    }

    function test_filledStateRequiresActualDelivery() public {
        TaxedCollateralTokenReview taxed = new TaxedCollateralTokenReview(100, dylan);
        IConditionalTokens taxedCtf = _deployConditionalTokens();
        bytes32 taxedConditionId = _prepareCondition(taxedCtf, admin, keccak256("taxed-review"));
        uint256 taxedYes = _positionId(taxedCtf, address(taxed), taxedConditionId, 1);
        CTFExchange taxedExchange =
            _deployExchange(address(taxed), address(taxedCtf), address(taxed), address(taxedCtf));

        taxed.mint(bob, 50_000_000);
        vm.prank(bob);
        taxed.approve(address(taxedExchange), 50_000_000);

        taxed.mint(admin, 100_000_000);
        vm.startPrank(admin);
        taxed.approve(address(taxedCtf), 100_000_000);
        taxedCtf.splitPosition(address(taxed), bytes32(0), taxedConditionId, _partition(), 100_000_000);
        ERC1155(address(taxedCtf)).safeTransferFrom(admin, carla, taxedYes, 100_000_000, "");
        vm.stopPrank();

        vm.prank(carla);
        ERC1155(address(taxedCtf)).setApprovalForAll(address(taxedExchange), true);

        Order memory takerOrder =
            _createAndSignOrder(taxedExchange, bobPK, taxedYes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder =
            _createAndSignOrder(taxedExchange, carlaPK, taxedYes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makers = new Order[](1);
        makers[0] = makerOrder;

        uint256[] memory fills = new uint256[](1);
        fills[0] = 100_000_000;

        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;

        vm.prank(admin);
        taxedExchange.matchOrders(taxedConditionId, takerOrder, makers, 50_000_000, fills, 0, fees);

        assertTrue(taxedExchange.getOrderStatus(taxedExchange.hashOrder(takerOrder)).filled);
        assertLt(taxed.balanceOf(carla), 50_000_000, "maker was not economically short-paid");
    }

    function _runComplementaryScenario(
        uint256[] memory makerFillAmounts,
        uint256 makerAmount,
        uint256 takerAmount
    ) internal returns (uint256 takerSpent, uint256 makerReceived, uint256 remaining) {
        USDC localUsdc = new USDC();
        IConditionalTokens localCtf = _deployConditionalTokens();
        bytes32 localConditionId =
            _prepareCondition(localCtf, admin, keccak256(abi.encodePacked("rounding-review", makerFillAmounts.length)));
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

    function _runPermutationScenario(bool reverse) internal returns (uint256 spent, uint256 received) {
        USDC localUsdc = new USDC();
        IConditionalTokens localCtf = _deployConditionalTokens();
        bytes32 localConditionId = _prepareCondition(localCtf, admin, keccak256(abi.encodePacked("permutation", reverse)));
        uint256 localYes = _positionId(localCtf, address(localUsdc), localConditionId, 1);
        CTFExchange localExchange =
            _deployExchange(address(localUsdc), address(localCtf), address(localUsdc), address(localCtf));

        localUsdc.mint(bob, 40_000_000);
        vm.prank(bob);
        localUsdc.approve(address(localExchange), 40_000_000);

        localUsdc.mint(admin, 100_000_000);
        vm.startPrank(admin);
        localUsdc.approve(address(localCtf), 100_000_000);
        localCtf.splitPosition(address(localUsdc), bytes32(0), localConditionId, _partition(), 100_000_000);
        ERC1155(address(localCtf)).safeTransferFrom(admin, carla, localYes, 50_000_000, "");
        ERC1155(address(localCtf)).safeTransferFrom(admin, dylan, localYes, 50_000_000, "");
        vm.stopPrank();

        vm.prank(carla);
        ERC1155(address(localCtf)).setApprovalForAll(address(localExchange), true);
        vm.prank(dylan);
        ERC1155(address(localCtf)).setApprovalForAll(address(localExchange), true);

        Order memory takerOrder =
            _createAndSignOrder(localExchange, bobPK, localYes, 40_000_000, 100_000_000, Side.BUY);
        Order memory makerA =
            _createAndSignOrder(localExchange, carlaPK, localYes, 50_000_000, 20_000_000, Side.SELL);
        Order memory makerB =
            _createAndSignOrder(localExchange, dylanPK, localYes, 50_000_000, 20_000_000, Side.SELL);

        Order[] memory makers = new Order[](2);
        if (reverse) {
            makers[0] = makerB;
            makers[1] = makerA;
        } else {
            makers[0] = makerA;
            makers[1] = makerB;
        }

        uint256[] memory makerFills = new uint256[](2);
        makerFills[0] = 50_000_000;
        makerFills[1] = 50_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = 0;
        makerFees[1] = 0;

        uint256 takerBefore = localUsdc.balanceOf(bob);
        uint256 makersBefore = localUsdc.balanceOf(carla) + localUsdc.balanceOf(dylan);

        vm.prank(admin);
        localExchange.matchOrders(localConditionId, takerOrder, makers, 40_000_000, makerFills, 0, makerFees);

        spent = takerBefore - localUsdc.balanceOf(bob);
        received = (localUsdc.balanceOf(carla) + localUsdc.balanceOf(dylan)) - makersBefore;
    }

    function dealUsdcAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(exchange), amount);
    }

    function dealOutcomeTokensAndApprove(address user, uint256 tokenId, uint256 amount) internal {
        usdc.mint(admin, amount);

        vm.startPrank(admin);
        usdc.approve(address(ctf), amount);
        ctf.splitPosition(address(usdc), bytes32(0), conditionId, _partition(), amount);
        ERC1155(address(ctf)).safeTransferFrom(admin, user, tokenId, amount, "");
        vm.stopPrank();

        vm.prank(user);
        ERC1155(address(ctf)).setApprovalForAll(address(exchange), true);
    }

    function _partition() internal pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
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
}
