// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ECDSA } from "@solady/src/utils/ECDSA.sol";
import { ERC20 } from "@solady/src/tokens/ERC20.sol";
import { ERC1155 } from "@solady/src/tokens/ERC1155.sol";

import { PolymarketAuditBase } from "./helpers/PolymarketAuditBase.sol";
import { USDC } from "@ctf-exchange-v2/src/test/dev/mocks/USDC.sol";
import { CTFExchange } from "@ctf-exchange-v2/src/exchange/CTFExchange.sol";
import { IConditionalTokens } from "@ctf-exchange-v2/src/adapters/interfaces/IConditionalTokens.sol";
import { Order, OrderStatus, Side } from "@ctf-exchange-v2/src/exchange/libraries/Structs.sol";
import { ERC1155TokenReceiver } from "@ctf-exchange-v2/src/exchange/mixins/ERC1155TokenReceiver.sol";

contract Rejecting1271Wallet {
    bytes4 internal constant MAGIC_VALUE_1271 = 0x1626ba7e;

    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function approveERC20(address token, address spender, uint256 amount) external {
        ERC20(token).approve(spender, amount);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) public view returns (bytes4) {
        return ECDSA.recover(hash, signature) == signer ? MAGIC_VALUE_1271 : bytes4(0);
    }
}

contract ReentrantMatch1271Wallet is ERC1155TokenReceiver {
    bytes4 internal constant MAGIC_VALUE_1271 = 0x1626ba7e;

    address public immutable signer;

    CTFExchange internal exchange;
    bytes32 internal conditionId;
    Order internal takerOrder;
    Order internal makerOrder;
    uint256 internal takerFillAmount;
    uint256 internal makerFillAmount;

    bool public attemptedReentry;
    bool public reentrySucceeded;
    bytes public reentryFailureData;

    constructor(address signer_) {
        signer = signer_;
    }

    function approveERC20(address token, address spender, uint256 amount) external {
        ERC20(token).approve(spender, amount);
    }

    function configureReentry(
        CTFExchange exchange_,
        bytes32 conditionId_,
        Order memory takerOrder_,
        Order memory makerOrder_,
        uint256 takerFillAmount_,
        uint256 makerFillAmount_
    ) external {
        exchange = exchange_;
        conditionId = conditionId_;
        takerOrder = takerOrder_;
        makerOrder = makerOrder_;
        takerFillAmount = takerFillAmount_;
        makerFillAmount = makerFillAmount_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) public view returns (bytes4) {
        return ECDSA.recover(hash, signature) == signer ? MAGIC_VALUE_1271 : bytes4(0);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        override
        returns (bytes4)
    {
        _attemptReentry();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        override
        returns (bytes4)
    {
        _attemptReentry();
        return this.onERC1155BatchReceived.selector;
    }

    function _attemptReentry() internal {
        if (attemptedReentry) return;
        attemptedReentry = true;

        Order[] memory makers = new Order[](1);
        makers[0] = makerOrder;

        uint256[] memory makerFills = new uint256[](1);
        makerFills[0] = makerFillAmount;

        uint256[] memory makerFees = new uint256[](1);
        makerFees[0] = 0;

        try exchange.matchOrders(conditionId, takerOrder, makers, takerFillAmount, makerFills, 0, makerFees) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            reentryFailureData = reason;
        }
    }
}

contract TaxedCollateralToken {
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

contract PolymarketExchangeInvariantTest is PolymarketAuditBase {
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
        conditionId = _prepareCondition(ctf, admin, keccak256("polymarket-exchange-question"));
        yes = _positionId(ctf, address(usdc), conditionId, 1);
        no = _positionId(ctf, address(usdc), conditionId, 2);

        exchange = _deployExchange(address(usdc), address(ctf), address(usdc), address(ctf));
    }

    function test_orderFillIsMonotonicAcrossPartialMatches() public {
        dealUsdcAndApprove(bob, 50_000_000);
        dealOutcomeTokensAndApprove(carla, yes, 50_000_000);
        dealOutcomeTokensAndApprove(dylan, yes, 50_000_000);

        Order memory takerOrder = _createAndSignOrder(exchange, bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrderA = _createAndSignOrder(exchange, carlaPK, yes, 50_000_000, 25_000_000, Side.SELL);
        Order memory makerOrderB = _createAndSignOrder(exchange, dylanPK, yes, 50_000_000, 25_000_000, Side.SELL);

        Order[] memory firstMakers = new Order[](1);
        firstMakers[0] = makerOrderA;

        uint256[] memory firstMakerFills = new uint256[](1);
        firstMakerFills[0] = 50_000_000;

        uint256[] memory zeroFees = new uint256[](1);
        zeroFees[0] = 0;

        vm.prank(admin);
        exchange.matchOrders(conditionId, takerOrder, firstMakers, 25_000_000, firstMakerFills, 0, zeroFees);

        OrderStatus memory statusAfterFirst = exchange.getOrderStatus(exchange.hashOrder(takerOrder));
        assertFalse(statusAfterFirst.filled);
        assertEq(statusAfterFirst.remaining, 25_000_000);
        assertEq(usdc.balanceOf(bob), 25_000_000);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes), 50_000_000);

        Order[] memory secondMakers = new Order[](1);
        secondMakers[0] = makerOrderB;

        uint256[] memory secondMakerFills = new uint256[](1);
        secondMakerFills[0] = 50_000_000;

        vm.prank(admin);
        exchange.matchOrders(conditionId, takerOrder, secondMakers, 25_000_000, secondMakerFills, 0, zeroFees);

        OrderStatus memory statusAfterSecond = exchange.getOrderStatus(exchange.hashOrder(takerOrder));
        assertTrue(statusAfterSecond.filled);
        assertEq(statusAfterSecond.remaining, 0);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(bob, yes), 100_000_000);

        vm.expectRevert();
        vm.prank(admin);
        exchange.matchOrders(conditionId, takerOrder, secondMakers, 1, secondMakerFills, 0, zeroFees);
    }

    function test_reentrancyOnErc1155ReceiveCannotOverfillOrder() public {
        uint256 collateralAmount = 50_000_000;
        ReentrantMatch1271Wallet wallet = new ReentrantMatch1271Wallet(bob);

        vm.prank(admin);
        exchange.addOperator(address(wallet));

        usdc.mint(address(wallet), collateralAmount);
        wallet.approveERC20(address(usdc), address(exchange), collateralAmount);

        dealOutcomeTokensAndApprove(carla, yes, 100_000_000);

        Order memory takerOrder =
            _createAndSign1271Order(exchange, bobPK, address(wallet), yes, collateralAmount, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(exchange, carlaPK, yes, 100_000_000, collateralAmount, Side.SELL);

        wallet.configureReentry(exchange, conditionId, takerOrder, makerOrder, collateralAmount, 100_000_000);

        Order[] memory makers = new Order[](1);
        makers[0] = makerOrder;

        uint256[] memory fills = new uint256[](1);
        fills[0] = 100_000_000;

        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;

        vm.prank(admin);
        exchange.matchOrders(conditionId, takerOrder, makers, collateralAmount, fills, 0, fees);

        assertTrue(wallet.attemptedReentry());
        assertFalse(wallet.reentrySucceeded());
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(carla), collateralAmount);
        assertEq(usdc.balanceOf(feeReceiver), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(address(wallet), yes), 100_000_000);
        assertEq(ERC1155(address(ctf)).balanceOf(carla, yes), 0);

        OrderStatus memory takerStatus = exchange.getOrderStatus(exchange.hashOrder(takerOrder));
        OrderStatus memory makerStatus = exchange.getOrderStatus(exchange.hashOrder(makerOrder));
        assertTrue(takerStatus.filled);
        assertEq(takerStatus.remaining, 0);
        assertTrue(makerStatus.filled);
        assertEq(makerStatus.remaining, 0);
    }

    function test_matchOrdersIsAllOrNothingWhenMintPathCannotDeliverTokens() public {
        uint256 amount = 50_000_000;
        Rejecting1271Wallet wallet = new Rejecting1271Wallet(bob);

        usdc.mint(address(wallet), amount);
        wallet.approveERC20(address(usdc), address(exchange), amount);

        dealUsdcAndApprove(carla, amount);

        Order memory takerOrder =
            _createAndSign1271Order(exchange, bobPK, address(wallet), yes, amount, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(exchange, carlaPK, no, amount, 100_000_000, Side.BUY);

        Order[] memory makers = new Order[](1);
        makers[0] = makerOrder;

        uint256[] memory fills = new uint256[](1);
        fills[0] = amount;

        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;

        vm.expectRevert();
        vm.prank(admin);
        exchange.matchOrders(conditionId, takerOrder, makers, amount, fills, 0, fees);

        assertEq(usdc.balanceOf(address(wallet)), amount);
        assertEq(usdc.balanceOf(carla), amount);
        assertEq(usdc.balanceOf(address(exchange)), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(address(wallet), yes), 0);
        assertEq(ERC1155(address(ctf)).balanceOf(carla, no), 0);

        OrderStatus memory takerStatus = exchange.getOrderStatus(exchange.hashOrder(takerOrder));
        OrderStatus memory makerStatus = exchange.getOrderStatus(exchange.hashOrder(makerOrder));
        assertFalse(takerStatus.filled);
        assertEq(takerStatus.remaining, 0);
        assertFalse(makerStatus.filled);
        assertEq(makerStatus.remaining, 0);
    }

    function test_documentedRisk_partialFillDustCanExtractValue() public {
        uint256[] memory singleFill = new uint256[](1);
        singleFill[0] = 10_000_001;

        uint256[] memory splitFills = new uint256[](11);
        for (uint256 i; i < 10; ++i) {
            splitFills[i] = 1_000_000;
        }
        splitFills[10] = 1;

        (uint256 singleBobSpent, uint256 singleCarlaReceived, uint256 singleBobYes, uint256 singleRemaining) =
            _runComplementaryFillScenario(singleFill);
        (uint256 splitBobSpent, uint256 splitCarlaReceived, uint256 splitBobYes, uint256 splitRemaining) =
            _runComplementaryFillScenario(splitFills);

        assertEq(singleBobYes, 10_000_001);
        assertEq(splitBobYes, 10_000_001);
        assertEq(singleBobSpent, 7_000_000);
        assertEq(singleCarlaReceived, 7_000_000);
        assertEq(singleRemaining, 0);

        assertEq(splitBobSpent, 6_999_990);
        assertEq(splitCarlaReceived, 6_999_990);
        assertEq(splitRemaining, 10);
        assertLt(splitBobSpent, singleBobSpent);
        assertLt(splitCarlaReceived, singleCarlaReceived);
    }

    function test_documentedRisk_feeOnTransferCollateralSilentlyUnderpaysMaker() public {
        TaxedCollateralToken taxed = new TaxedCollateralToken(100, dylan);
        IConditionalTokens taxedCtf = _deployConditionalTokens();
        bytes32 taxedConditionId = _prepareCondition(taxedCtf, admin, keccak256("taxed-collateral"));
        uint256 taxedYes = _positionId(taxedCtf, address(taxed), taxedConditionId, 1);

        CTFExchange taxedExchange = _deployExchange(address(taxed), address(taxedCtf), address(taxed), address(taxedCtf));

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

        assertEq(ERC1155(address(taxedCtf)).balanceOf(bob, taxedYes), 100_000_000);
        assertEq(taxed.balanceOf(carla), 49_500_000);
        assertEq(taxed.balanceOf(dylan), 1_500_000);
        assertTrue(taxed.balanceOf(carla) < 50_000_000);
        assertTrue(taxedExchange.getOrderStatus(taxedExchange.hashOrder(takerOrder)).filled);
        assertTrue(taxedExchange.getOrderStatus(taxedExchange.hashOrder(makerOrder)).filled);
    }

    function test_hashOrderIsDomainSeparatedByVerifyingContract() public {
        CTFExchange exchange2 = _deployExchange(address(usdc), address(ctf), address(usdc), address(ctf));
        Order memory order = _createOrder(bob, yes, 50_000_000, 100_000_000, Side.BUY);

        bytes32 exchange1Hash = exchange.hashOrder(order);
        bytes32 exchange2Hash = exchange2.hashOrder(order);

        assertEq(
            exchange1Hash,
            keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(exchange)), _expectedStructHash(order)))
        );
        assertEq(
            exchange2Hash,
            keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(exchange2)), _expectedStructHash(order)))
        );
        assertTrue(exchange1Hash != exchange2Hash);
    }

    function test_signatureCannotReplayAcrossExchangeInstances() public {
        CTFExchange exchange2 = _deployExchange(address(usdc), address(ctf), address(usdc), address(ctf));
        Order memory order = _createAndSignOrder(exchange, bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        vm.expectRevert();
        exchange2.validateOrder(order);
    }

    function _runComplementaryFillScenario(uint256[] memory makerFillAmounts)
        internal
        returns (uint256 bobSpent, uint256 carlaReceived, uint256 bobYesReceived, uint256 takerRemaining)
    {
        USDC localUsdc = new USDC();
        IConditionalTokens localCtf = _deployConditionalTokens();
        bytes32 localConditionId = _prepareCondition(localCtf, admin, keccak256(abi.encodePacked("rounding", makerFillAmounts.length)));
        uint256 localYes = _positionId(localCtf, address(localUsdc), localConditionId, 1);

        CTFExchange localExchange = _deployExchange(address(localUsdc), address(localCtf), address(localUsdc), address(localCtf));

        localUsdc.mint(bob, 7_000_000);
        vm.prank(bob);
        localUsdc.approve(address(localExchange), 7_000_000);

        localUsdc.mint(admin, 10_000_001);
        vm.startPrank(admin);
        localUsdc.approve(address(localCtf), 10_000_001);
        localCtf.splitPosition(address(localUsdc), bytes32(0), localConditionId, _partition(), 10_000_001);
        ERC1155(address(localCtf)).safeTransferFrom(admin, carla, localYes, 10_000_001, "");
        vm.stopPrank();

        vm.prank(carla);
        ERC1155(address(localCtf)).setApprovalForAll(address(localExchange), true);

        Order memory takerOrder =
            _createAndSignOrder(localExchange, bobPK, localYes, 7_000_000, 10_000_001, Side.BUY);
        Order memory makerOrder =
            _createAndSignOrder(localExchange, carlaPK, localYes, 10_000_001, 7_000_000, Side.SELL);

        uint256 bobUsdcBefore = localUsdc.balanceOf(bob);
        uint256 carlaUsdcBefore = localUsdc.balanceOf(carla);

        for (uint256 i; i < makerFillAmounts.length; ++i) {
            Order[] memory makers = new Order[](1);
            makers[0] = makerOrder;

            uint256[] memory makerFills = new uint256[](1);
            makerFills[0] = makerFillAmounts[i];

            uint256[] memory makerFees = new uint256[](1);
            makerFees[0] = 0;

            uint256 takerFill = makerFillAmounts[i] * 7_000_000 / 10_000_001;

            vm.prank(admin);
            localExchange.matchOrders(localConditionId, takerOrder, makers, takerFill, makerFills, 0, makerFees);
        }

        bobSpent = bobUsdcBefore - localUsdc.balanceOf(bob);
        carlaReceived = localUsdc.balanceOf(carla) - carlaUsdcBefore;
        bobYesReceived = ERC1155(address(localCtf)).balanceOf(bob, localYes);
        takerRemaining = localExchange.getOrderStatus(localExchange.hashOrder(takerOrder)).remaining;
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
