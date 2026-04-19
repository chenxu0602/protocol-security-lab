// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {ERC20} from 'solmate/tokens/ERC20.sol';
import {ERC1155} from 'solmate/tokens/ERC1155.sol';
import {IERC20} from 'openzeppelin/token/ERC20/IERC20.sol';
import {IERC1155} from 'openzeppelin/token/ERC1155/IERC1155.sol';

import {FeeModule} from 'polymarket/exchange-fee-module/src/FeeModule.sol';
import {CalculatorHelper} from 'polymarket/exchange-fee-module/src/libraries/CalculatorHelper.sol';
import {
    Order,
    OrderStatus,
    Side,
    SignatureType
} from 'polymarket/exchange-fee-module/src/libraries/Structs.sol';

interface IOldExchangeLike {
    function registerToken(uint256 token, uint256 complement, bytes32 conditionId) external;

    function addOperator(address operator) external;

    function addAdmin(address admin) external;

    function getCollateral() external view returns (address);

    function getCtf() external view returns (address);

    function hashOrder(Order memory order) external view returns (bytes32);

    function getOrderStatus(bytes32 orderHash) external view returns (OrderStatus memory);

    function getMaxFeeRate() external view returns (uint256);
}

interface IConditionalTokensLike {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);

    function getPositionId(IERC20 collateralToken, bytes32 collectionId)
        external
        pure
        returns (uint256);
}

contract MockUSDC is ERC20 {
    constructor() ERC20('USD Coin', 'USDC', 6) {}
}

contract PolymarketFeeModuleInvariantTest is Test {
    uint256 internal constant BOB_PK = 0xB0B;
    uint256 internal constant CARLA_PK = 0xCA414;
    bytes32 internal constant QUESTION_ID = hex'1234';

    address internal admin = address(1);
    address internal outsider = address(2);
    address internal bob;
    address internal carla;

    MockUSDC internal usdc;
    address internal ctf;
    IOldExchangeLike internal exchange;
    FeeModule internal feeModule;

    bytes32 internal conditionId;
    uint256 internal yes;
    uint256 internal no;
    uint256 internal nextSalt = 1;

    function setUp() public {
        bob = vm.addr(BOB_PK);
        carla = vm.addr(CARLA_PK);

        vm.label(admin, 'admin');
        vm.label(outsider, 'outsider');
        vm.label(bob, 'bob');
        vm.label(carla, 'carla');

        usdc = new MockUSDC();
        ctf = _deployCode('lib/polymarket/exchange-fee-module/artifacts/ConditionalTokens.json', '');
        exchange = IOldExchangeLike(
            _deployCode(
                'lib/polymarket/exchange-fee-module/artifacts/Exchange.json',
                abi.encode(address(usdc), ctf, address(0), address(0))
            )
        );

        exchange.addAdmin(admin);
        exchange.addOperator(admin);

        IConditionalTokensLike conditionalTokens = IConditionalTokensLike(ctf);
        conditionalTokens.prepareCondition(admin, QUESTION_ID, 2);
        conditionId = conditionalTokens.getConditionId(admin, QUESTION_ID, 2);
        yes = conditionalTokens.getPositionId(
            IERC20(address(usdc)), conditionalTokens.getCollectionId(bytes32(0), conditionId, 2)
        );
        no = conditionalTokens.getPositionId(
            IERC20(address(usdc)), conditionalTokens.getCollectionId(bytes32(0), conditionId, 1)
        );

        vm.prank(admin);
        exchange.registerToken(yes, no, conditionId);

        vm.prank(admin);
        exchange.addOperator(address(feeModule = new FeeModule(address(exchange))));

        _dealAndMint(bob, 20_000_000_000);
        _dealAndMint(carla, 20_000_000_000);
    }

    function test_feeSinkDeltaMatchesChargedFeeOnComplementaryMatch() public {
        Order memory takerOrder =
            _createAndSignOrder(BOB_PK, yes, 40_000_000, 100_000_000, Side.BUY, 1000);
        Order memory makerOrderA =
            _createAndSignOrder(CARLA_PK, yes, 60_000_000, 24_000_000, Side.SELL, 100);
        Order memory makerOrderB =
            _createAndSignOrder(CARLA_PK, yes, 100_000_000, 40_000_000, Side.SELL, 100);

        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = makerOrderA;
        makerOrders[1] = makerOrderB;

        uint256[] memory makerFillAmounts = new uint256[](2);
        makerFillAmounts[0] = 60_000_000;
        makerFillAmounts[1] = 40_000_000;

        uint256 takerFillAmount = 40_000_000;
        uint256 takerReceiveAmount = 100_000_000;
        uint256 operatorTakerFeeAmount = 5_000_000;

        uint256[] memory operatorMakerFeeAmounts = new uint256[](2);
        operatorMakerFeeAmounts[0] = 120_000;
        operatorMakerFeeAmounts[1] = 80_000;

        uint256 moduleYesBefore = _balanceOf1155(address(feeModule), yes);
        uint256 moduleUsdcBefore = _balanceOf(address(feeModule));
        uint256 bobYesBefore = _balanceOf1155(bob, yes);
        uint256 carlaUsdcBefore = _balanceOf(carla);

        vm.prank(admin);
        feeModule.matchOrders(
            takerOrder,
            makerOrders,
            takerFillAmount,
            takerReceiveAmount,
            makerFillAmounts,
            operatorTakerFeeAmount,
            operatorMakerFeeAmounts
        );

        assertEq(_balanceOf1155(address(feeModule), yes) - moduleYesBefore, operatorTakerFeeAmount);
        assertEq(
            _balanceOf(address(feeModule)) - moduleUsdcBefore,
            operatorMakerFeeAmounts[0] + operatorMakerFeeAmounts[1]
        );

        assertEq(
            _balanceOf1155(bob, yes) - bobYesBefore, takerReceiveAmount - operatorTakerFeeAmount
        );
        assertEq(
            _balanceOf(carla) - carlaUsdcBefore,
            (24_000_000 - operatorMakerFeeAmounts[0]) + (16_000_000 - operatorMakerFeeAmounts[1])
        );
    }

    function test_refundRecipientBindingDoesNotCreditCallerOrThirdParty() public {
        Order memory takerOrder =
            _createAndSignOrder(BOB_PK, yes, 40_000_000, 100_000_000, Side.BUY, 1000);
        Order memory makerOrderA =
            _createAndSignOrder(CARLA_PK, yes, 60_000_000, 24_000_000, Side.SELL, 100);
        Order memory makerOrderB =
            _createAndSignOrder(CARLA_PK, yes, 100_000_000, 40_000_000, Side.SELL, 100);

        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = makerOrderA;
        makerOrders[1] = makerOrderB;

        uint256[] memory makerFillAmounts = new uint256[](2);
        makerFillAmounts[0] = 60_000_000;
        makerFillAmounts[1] = 40_000_000;

        uint256[] memory operatorMakerFeeAmounts = new uint256[](2);
        operatorMakerFeeAmounts[0] = 120_000;
        operatorMakerFeeAmounts[1] = 80_000;

        uint256 adminUsdcBefore = _balanceOf(admin);
        uint256 adminYesBefore = _balanceOf1155(admin, yes);
        uint256 outsiderUsdcBefore = _balanceOf(outsider);
        uint256 outsiderYesBefore = _balanceOf1155(outsider, yes);

        vm.prank(admin);
        feeModule.matchOrders(
            takerOrder,
            makerOrders,
            40_000_000,
            100_000_000,
            makerFillAmounts,
            5_000_000,
            operatorMakerFeeAmounts
        );

        assertEq(_balanceOf(admin), adminUsdcBefore);
        assertEq(_balanceOf1155(admin, yes), adminYesBefore);
        assertEq(_balanceOf(outsider), outsiderUsdcBefore);
        assertEq(_balanceOf1155(outsider, yes), outsiderYesBefore);
    }

    function test_documentedRisk_inflatedTakerReceiveAmountUsesHistoricalBalanceForOverRefund()
        public
    {
        Order memory takerOrder =
            _createAndSignOrder(BOB_PK, yes, 40_000_000, 100_000_000, Side.BUY, 1000);
        Order memory makerOrderA =
            _createAndSignOrder(CARLA_PK, yes, 60_000_000, 24_000_000, Side.SELL, 100);
        Order memory makerOrderB =
            _createAndSignOrder(CARLA_PK, yes, 100_000_000, 40_000_000, Side.SELL, 100);

        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = makerOrderA;
        makerOrders[1] = makerOrderB;

        uint256[] memory makerFillAmounts = new uint256[](2);
        makerFillAmounts[0] = 60_000_000;
        makerFillAmounts[1] = 40_000_000;

        uint256 operatorTakerFeeAmount = 5_000_000;
        uint256 actualReceiveAmount = 100_000_000;
        uint256 inflatedReceiveAmount = 200_000_000;

        uint256[] memory operatorMakerFeeAmounts = new uint256[](2);
        operatorMakerFeeAmounts[0] = 120_000;
        operatorMakerFeeAmounts[1] = 80_000;

        uint256 theoreticalTakerFee =
            _calculateTakerExchangeFee(takerOrder, 40_000_000, actualReceiveAmount);
        uint256 inflatedRefund = _calculateTakerRefund(
            takerOrder, 40_000_000, inflatedReceiveAmount, operatorTakerFeeAmount
        );
        uint256 historicalBalanceConsumed = inflatedRefund - theoreticalTakerFee;

        // Negative control: without pre-existing fee inventory, the inflated refund path cannot pay out.
        vm.expectRevert();
        vm.prank(admin);
        feeModule.matchOrders(
            takerOrder,
            makerOrders,
            40_000_000,
            inflatedReceiveAmount,
            makerFillAmounts,
            operatorTakerFeeAmount,
            operatorMakerFeeAmounts
        );

        // Seed exactly the amount of historical fee inventory needed to satisfy the over-refund.
        uint256 bobYesBefore = _balanceOf1155(bob, yes);
        _transfer1155(bob, address(feeModule), yes, historicalBalanceConsumed);
        uint256 moduleYesBefore = _balanceOf1155(address(feeModule), yes);

        // Exploit path: same malformed execution now succeeds because refund can consume old inventory.
        vm.prank(admin);
        feeModule.matchOrders(
            takerOrder,
            makerOrders,
            40_000_000,
            inflatedReceiveAmount,
            makerFillAmounts,
            operatorTakerFeeAmount,
            operatorMakerFeeAmounts
        );

        assertEq(moduleYesBefore, historicalBalanceConsumed);
        assertEq(_balanceOf1155(address(feeModule), yes), 0);
        assertEq(
            _balanceOf1155(bob, yes) - bobYesBefore,
            actualReceiveAmount - operatorTakerFeeAmount + historicalBalanceConsumed
        );
    }


    function test_documentedRisk_refundExcessEqualsHistoricalFeeInventoryConsumed() public {
        //
        // -------------------------
        // Stage 1: build legitimate historical fee inventory
        // -------------------------
        //
        Order memory normalTakerOrder =
            _createAndSignOrder(BOB_PK, yes, 40_000_000, 100_000_000, Side.BUY, 1000);
        Order memory normalMakerOrderA =
            _createAndSignOrder(CARLA_PK, yes, 60_000_000, 24_000_000, Side.SELL, 100);
        Order memory normalMakerOrderB =
            _createAndSignOrder(CARLA_PK, yes, 100_000_000, 40_000_000, Side.SELL, 100);

        Order[] memory normalMakerOrders = new Order[](2);
        normalMakerOrders[0] = normalMakerOrderA;
        normalMakerOrders[1] = normalMakerOrderB;

        uint256[] memory normalMakerFillAmounts = new uint256[](2);
        normalMakerFillAmounts[0] = 60_000_000;
        normalMakerFillAmounts[1] = 40_000_000;

        uint256[] memory normalMakerFeeAmounts = new uint256[](2);
        normalMakerFeeAmounts[0] = 120_000;
        normalMakerFeeAmounts[1] = 80_000;

        uint256 operatorTakerFeeAmount = 5_000_000;
        uint256 actualReceiveAmount = 100_000_000;
        uint256 inflatedReceiveAmount = 200_000_000;

        uint256 moduleYesBeforeNormal = _balanceOf1155(address(feeModule), yes);

        vm.prank(admin);
        feeModule.matchOrders(
            normalTakerOrder,
            normalMakerOrders,
            40_000_000,
            actualReceiveAmount,
            normalMakerFillAmounts,
            operatorTakerFeeAmount,
            normalMakerFeeAmounts
        );

        uint256 legitimateFeeInventory =
            _balanceOf1155(address(feeModule), yes) - moduleYesBeforeNormal;

        // On this legacy FeeModule path, a normal match leaves the operator taker fee
        // as YES inventory in the module.
        assertEq(legitimateFeeInventory, operatorTakerFeeAmount);

        //
        // -------------------------
        // Stage 2: malformed execution with fresh orders
        // -------------------------
        //
        Order memory exploitTakerOrder =
            _createAndSignOrder(BOB_PK, yes, 40_000_000, 100_000_000, Side.BUY, 1000);
        Order memory exploitMakerOrderA =
            _createAndSignOrder(CARLA_PK, yes, 60_000_000, 24_000_000, Side.SELL, 100);
        Order memory exploitMakerOrderB =
            _createAndSignOrder(CARLA_PK, yes, 100_000_000, 40_000_000, Side.SELL, 100);

        Order[] memory exploitMakerOrders = new Order[](2);
        exploitMakerOrders[0] = exploitMakerOrderA;
        exploitMakerOrders[1] = exploitMakerOrderB;

        uint256[] memory exploitMakerFillAmounts = new uint256[](2);
        exploitMakerFillAmounts[0] = 60_000_000;
        exploitMakerFillAmounts[1] = 40_000_000;

        uint256[] memory exploitMakerFeeAmounts = new uint256[](2);
        exploitMakerFeeAmounts[0] = 120_000;
        exploitMakerFeeAmounts[1] = 80_000;

        uint256 inflatedRefund = _calculateTakerRefund(
            exploitTakerOrder, 40_000_000, inflatedReceiveAmount, operatorTakerFeeAmount
        );

        // Seed only the extra history needed beyond the normal fee inventory.
        uint256 extraHistoricalInventoryNeeded = inflatedRefund - legitimateFeeInventory;
        _transfer1155(bob, address(feeModule), yes, extraHistoricalInventoryNeeded);

        uint256 bobYesBeforeExploit = _balanceOf1155(bob, yes);
        uint256 moduleYesBeforeExploit = _balanceOf1155(address(feeModule), yes);

        vm.prank(admin);
        feeModule.matchOrders(
            exploitTakerOrder,
            exploitMakerOrders,
            40_000_000,
            inflatedReceiveAmount,
            exploitMakerFillAmounts,
            operatorTakerFeeAmount,
            exploitMakerFeeAmounts
        );

        uint256 bobYesAfterExploit = _balanceOf1155(bob, yes);
        uint256 moduleYesAfterExploit = _balanceOf1155(address(feeModule), yes);

        uint256 bobYesGain = bobYesAfterExploit - bobYesBeforeExploit;

        // Normal path would give the taker exactly actualReceiveAmount - fee.
        uint256 normalNetReceive = actualReceiveAmount - operatorTakerFeeAmount;

        // What the taker got above the normal path is the over-refund funded by history.
        uint256 excessReceive = bobYesGain - normalNetReceive;

        // Net module balance delta alone is NOT enough, because this exploit tx also
        // contributes a fresh taker fee into the module.
        uint256 grossHistoricalConsumption =
            moduleYesBeforeExploit + operatorTakerFeeAmount - moduleYesAfterExploit;

        // The taker’s excess receive is exactly the historical inventory consumed.
        assertEq(excessReceive, grossHistoricalConsumption);

        // And this should equal the amount we intentionally seeded as extra history.
        assertEq(excessReceive, extraHistoricalInventoryNeeded);

        // Sanity: without malformed refund, the module would have ended with
        // (preexisting inventory + fresh taker fee). Instead it ends lower by the drained amount.
        assertEq(
            moduleYesAfterExploit,
            moduleYesBeforeExploit + operatorTakerFeeAmount - excessReceive
        );
    }


    function _createAndSignOrder(
        uint256 signerPk,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side,
        uint256 feeRateBps
    ) internal returns (Order memory order) {
        address maker = vm.addr(signerPk);
        order = Order({
            salt: nextSalt++,
            maker: maker,
            signer: maker,
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: feeRateBps,
            side: side,
            signatureType: SignatureType.EOA,
            signature: new bytes(0)
        });

        bytes32 orderHash = exchange.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, orderHash);
        order.signature = abi.encodePacked(r, s, v);
    }

    function _dealAndMint(address trader, uint256 collateralAmount) internal {
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        deal(address(usdc), trader, collateralAmount);

        vm.startPrank(trader);
        usdc.approve(ctf, type(uint256).max);
        usdc.approve(address(exchange), type(uint256).max);
        IERC1155(ctf).setApprovalForAll(address(exchange), true);
        IConditionalTokensLike(ctf)
            .splitPosition(
                IERC20(address(usdc)), bytes32(0), conditionId, partition, collateralAmount / 2
            );
        vm.stopPrank();
    }

    function _calculateTakerExchangeFee(
        Order memory order,
        uint256 fillAmount,
        uint256 receiveAmount
    ) internal pure returns (uint256) {
        return CalculatorHelper.calculateExchangeFee(
            order.feeRateBps,
            order.side == Side.BUY ? receiveAmount : fillAmount,
            fillAmount,
            receiveAmount,
            order.side
        );
    }

    function _calculateTakerRefund(
        Order memory order,
        uint256 fillAmount,
        uint256 receiveAmount,
        uint256 operatorFeeAmount
    ) internal pure returns (uint256) {
        return CalculatorHelper.calculateRefund(
            order.feeRateBps,
            operatorFeeAmount,
            order.side == Side.BUY ? receiveAmount : fillAmount,
            fillAmount,
            receiveAmount,
            order.side
        );
    }

    function _balanceOf(address account) internal view returns (uint256) {
        return usdc.balanceOf(account);
    }

    function _balanceOf1155(address account, uint256 id) internal view returns (uint256) {
        return ERC1155(ctf).balanceOf(account, id);
    }

    function _transfer1155(address from, address to, uint256 id, uint256 amount) internal {
        vm.prank(from);
        ERC1155(ctf).safeTransferFrom(from, to, id, amount, '');
    }

    function _deployCode(string memory path, bytes memory args)
        internal
        returns (address deployment)
    {
        bytes memory bytecode = abi.encodePacked(vm.getCode(path), args);
        assembly {
            deployment := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }
}