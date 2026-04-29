// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@solady/src/tokens/ERC20.sol";
import { ERC1155 } from "@solady/src/tokens/ERC1155.sol";

import { PolymarketAuditBase } from "./helpers/PolymarketAuditBase.sol";
import { USDC } from "@ctf-exchange-v2/src/test/dev/mocks/USDC.sol";
import { CTFExchange } from "@ctf-exchange-v2/src/exchange/CTFExchange.sol";
import { IConditionalTokens } from "@ctf-exchange-v2/src/adapters/interfaces/IConditionalTokens.sol";
import { Order, Side } from "@ctf-exchange-v2/src/exchange/libraries/Structs.sol";

contract PolymarketProtocolPrincipalInvariantTest is PolymarketAuditBase {
    USDC internal usdc;
    IConditionalTokens internal ctf;
    CTFExchange internal exchange;
    bytes32 internal conditionId;
    uint256 internal yes;
    uint256 internal no;

    function setUp() public {
        _setUpActors();

        usdc = new USDC();
        ctf = _deployConditionalTokens();
        conditionId = _prepareCondition(ctf, admin, keccak256("polymarket-protocol-principal"));
        yes = _positionId(ctf, address(usdc), conditionId, 1);
        no = _positionId(ctf, address(usdc), conditionId, 2);

        exchange = _deployExchange(address(usdc), address(ctf), address(usdc), address(ctf));
    }

    function test_complementaryMatchLeavesNoProtocolPrincipal() public {
        dealUsdcAndApprove(bob, 50_000_000);
        dealOutcomeTokensAndApprove(carla, yes, 100_000_000);

        Order memory takerOrder =
            _createAndSignOrder(exchange, bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder =
            _createAndSignOrder(exchange, carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        _matchSingleMaker(takerOrder, makerOrder, 50_000_000, 100_000_000);

        assertNoProtocolPrincipal();
        assertEq(usdc.balanceOf(carla), 50_000_000);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes), 100_000_000);
    }

    function test_mintPathLeavesNoProtocolPrincipal() public {
        dealUsdcAndApprove(bob, 40_000_000);
        dealUsdcAndApprove(carla, 60_000_000);

        Order memory takerOrder =
            _createAndSignOrder(exchange, bobPK, yes, 40_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder =
            _createAndSignOrder(exchange, carlaPK, no, 60_000_000, 100_000_000, Side.BUY);

        _matchSingleMaker(takerOrder, makerOrder, 40_000_000, 60_000_000);

        assertNoProtocolPrincipal();
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes), 100_000_000);
        assertEq(ERC1155(address(ctf)).balanceOf(carla, no), 100_000_000);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(carla), 0);
    }

    function test_mergePathLeavesNoProtocolPrincipal() public {
        dealOutcomeTokensAndApprove(bob, yes, 100_000_000);
        dealOutcomeTokensAndApprove(carla, no, 100_000_000);

        Order memory takerOrder =
            _createAndSignOrder(exchange, bobPK, yes, 100_000_000, 40_000_000, Side.SELL);
        Order memory makerOrder =
            _createAndSignOrder(exchange, carlaPK, no, 100_000_000, 60_000_000, Side.SELL);

        _matchSingleMaker(takerOrder, makerOrder, 100_000_000, 100_000_000);

        assertNoProtocolPrincipal();
        assertEq(usdc.balanceOf(bob), 40_000_000);
        assertEq(usdc.balanceOf(carla), 60_000_000);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(carla, no), 0);
    }

    function _matchSingleMaker(
        Order memory takerOrder,
        Order memory makerOrder,
        uint256 takerFillAmount,
        uint256 makerFillAmount
    ) internal {
        Order[] memory makers = new Order[](1);
        makers[0] = makerOrder;

        uint256[] memory makerFills = new uint256[](1);
        makerFills[0] = makerFillAmount;

        uint256[] memory makerFees = new uint256[](1);
        makerFees[0] = 0;

        vm.prank(admin);
        exchange.matchOrders(conditionId, takerOrder, makers, takerFillAmount, makerFills, 0, makerFees);
    }

    function assertNoProtocolPrincipal() internal view {
        assertEq(usdc.balanceOf(address(exchange)), 0);
        assertEq(usdc.balanceOf(feeReceiver), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(address(exchange), yes), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(address(exchange), no), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(feeReceiver, yes), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(feeReceiver, no), 0);
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
}
