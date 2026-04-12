// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {Morpho} from "../../../src/review/Morpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../../../src/review/MockERC20.sol";

import {MorphoHandler} from "../handlers/MorphoHandler.sol";

import {
    IMorpho,
    Authorization,
    Id,
    Market,
    MarketParams,
    Position,
    Signature
} from "../../../src/review/interfaces/IMorpho.sol";
import {IIrm} from "../../../src/review/interfaces/IIrm.sol";
import {IOracle} from "../../../src/review/interfaces/IOracle.sol";
import {IMorphoSupplyCallback} from "../../../src/review/interfaces/IMorphoCallbacks.sol";
import {ErrorsLib} from "../../../src/review/libraries/ErrorsLib.sol";
import {MarketParamsLib} from "../../../src/review/libraries/MarketParamsLib.sol";
import {
    AUTHORIZATION_TYPEHASH,
    LIQUIDATION_CURSOR,
    MAX_LIQUIDATION_INCENTIVE_FACTOR,
    ORACLE_PRICE_SCALE
} from "../../../src/review/libraries/ConstantsLib.sol";



contract FixedRateIrmReview is IIrm {
    uint256 public ratePerSecond;

    constructor(uint256 _ratePerSecond) {
        ratePerSecond = _ratePerSecond;
    }

    function setRatePerSecond(uint256 _ratePerSecond) external {
        ratePerSecond = _ratePerSecond;
    }

    function borrowRate(MarketParams memory, Market memory) external view returns (uint256) {
        return ratePerSecond;
    }

    function borrowRateView(MarketParams memory, Market memory) external view returns (uint256) {
        return ratePerSecond;
    }
}

contract MutableOracleReview is IOracle {
    uint256 public currentPrice;

    constructor(uint256 _currentPrice) {
        currentPrice = _currentPrice;
    }

    function setPrice(uint256 _currentPrice) external {
        currentPrice = _currentPrice;
    }

    function price() external view returns (uint256) {
        return currentPrice;
    }
}

contract RevertingSupplyCallback is IMorphoSupplyCallback {
    IMorpho internal immutable morpho;
    MarketParams internal marketParams;

    constructor(IMorpho _morpho, MarketParams memory _marketParams) {
        morpho = _morpho;
        marketParams = _marketParams;
    }

    function run(uint256 assets, address onBehalf) external {
        morpho.supply(marketParams, assets, 0, onBehalf, hex"01");
    }

    function onMorphoSupply(uint256, bytes calldata) external pure {
        revert("callback revert");
    }
}



contract MorphoInvariants is StdInvariant, Test {
    IMorpho public morpho;
    MockERC20 public loanToken;
    MockERC20 public collateralToken;

    MorphoHandler public handler;

    address public supplier1;
    address public borrower1;
    address public borrower2;
    address public liquidator;

    FixedRateIrmReview internal irm;
    MutableOracleReview internal oracle;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant INITIAL_PRICE = 1e36;
    uint256 internal constant STARTING_BALANCE = 10_000 ether;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal supplier = makeAddr("supplier");
    address internal secondSupplier = makeAddr("secondSupplier");
    // address internal borrower = makeAddr("borrower");
    // address internal liquidator = makeAddr("liquidator");
    address internal delegate = makeAddr("delegate");
    uint256 internal authorizerPk;
    address internal authorizer;

    MarketParams internal marketParams;
    Id internal marketId;

    function setUp() public {
        supplier1 = makeAddr("supplier1");
        borrower1 = makeAddr("borrower1");
        borrower2 = makeAddr("borrower2");
        liquidator = makeAddr("liquidator");

        _setUpMorphoEnvironment();

        handler = new MorphoHandler(
            morpho, 
            IERC20(address(loanToken)), 
            IERC20(address(collateralToken)), 
            marketParams, 
            supplier1, 
            borrower1, 
            borrower2, 
            liquidator
        );

        targetContract(address(handler));
    }

    function _setUpMorphoEnvironment() internal {

        vm.warp(1_700_000_000);

        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COLL", 18);
        oracle = new MutableOracleReview(INITIAL_PRICE);
        irm = new FixedRateIrmReview(0);

        vm.prank(owner);
        morpho = IMorpho(address(new Morpho(owner)));

        vm.startPrank(owner);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(LLTV);
        morpho.setFeeRecipient(feeRecipient);
        vm.stopPrank();

        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });
        marketId = Id.wrap(keccak256(abi.encode(marketParams)));

        morpho.createMarket(marketParams);

        // _mintAndApprove(supplier, STARTING_BALANCE, STARTING_BALANCE);
        // _mintAndApprove(secondSupplier, STARTING_BALANCE, STARTING_BALANCE);
        // _mintAndApprove(borrower, STARTING_BALANCE, STARTING_BALANCE);
        // _mintAndApprove(liquidator, STARTING_BALANCE, STARTING_BALANCE);
        // _mintAndApprove(delegate, STARTING_BALANCE, STARTING_BALANCE);

        authorizerPk = 0xA11CE;
        authorizer = vm.addr(authorizerPk);
    }


    function _mintAndApprove(address user, uint256 loanAmount, uint256 collateralAmount) internal {
        loanToken.mint(user, loanAmount);
        collateralToken.mint(user, collateralAmount);

        vm.startPrank(user);
        loanToken.approve(address(morpho), type(uint256).max);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.stopPrank();
    }

    function _mintAndApproveFor(
        IMorpho targetMorpho,
        MockERC20 loan,
        MockERC20 collateral,
        address user,
        uint256 loanAmount,
        uint256 collateralAmount
    ) internal {
        loan.mint(user, loanAmount);
        collateral.mint(user, collateralAmount);

        vm.startPrank(user);
        loan.approve(address(targetMorpho), type(uint256).max);
        collateral.approve(address(targetMorpho), type(uint256).max);
        vm.stopPrank();
    }

    function test_handler_smoke_makes_progress() public {
        handler.supply(1000 ether);
        handler.supplyCollateral(0, 1000 ether);
        handler.borrow(0, 100 ether);
        handler.warp(1 days);

        uint256 successes = 
            handler.successfulSupplies() +
            handler.successfulCollateralSupplies() + 
            handler.successfulBorrows() +
            handler.successfulRepays() +
            handler.successfulLiquidations() +
            handler.totalWarps();

        assertGt(successes, 0);
    }

    function invariant_market_totals_are_ordered() public view {
        (uint128 totalSupplyAssets, , uint128 totalBorrowAssets,) = handler.marketTotals();
        assertLe(uint256(totalBorrowAssets), uint256(totalSupplyAssets));
    }

    function test_observe_last_liquidation_tracking() public {
        handler.supply(1000 ether);
        handler.supplyCollateral(0, 1000 ether);
        handler.borrow(0, 100 ether);
        handler.warp(7 days);
        handler.liquidate(0, 10 ether);

        address target = handler.lastLiquidationTarget();
        uint256 amount = handler.lastLiquidationAttemptAmount();
        bool ok = handler.lastLiquidationSucceeded();

        assertEq(target, borrower1);
        assertGt(amount, 0);

        ok;
    }

    function invariant_successful_liquidation_requires_existing_debt() public view {
        if (handler.lastLiquidationSucceeded()) {
            assertGt(handler.lastLiquidationTargetBorrowSharesBefore(), 0);
        }
    }

    function invariant_successful_liquidation_requires_collateral() public view {
        if (handler.lastLiquidationSucceeded()) {
            assertGt(handler.lastLiquidationTargetCollateralBefore(), 0);
        }
    }
}