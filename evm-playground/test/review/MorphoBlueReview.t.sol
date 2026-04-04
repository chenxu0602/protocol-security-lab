// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";

import {Morpho} from "../../src/review/Morpho.sol";
import {
    IMorpho,
    Authorization,
    Id,
    Market,
    MarketParams,
    Position,
    Signature
} from "../../src/review/interfaces/IMorpho.sol";
import {IIrm} from "../../src/review/interfaces/IIrm.sol";
import {IOracle} from "../../src/review/interfaces/IOracle.sol";
import {IMorphoSupplyCallback} from "../../src/review/interfaces/IMorphoCallbacks.sol";
import {MockERC20} from "../../src/review/MockERC20.sol";
import {ErrorsLib} from "../../src/review/libraries/ErrorsLib.sol";
import {MarketParamsLib} from "../../src/review/libraries/MarketParamsLib.sol";
import {
    AUTHORIZATION_TYPEHASH,
    LIQUIDATION_CURSOR,
    MAX_LIQUIDATION_INCENTIVE_FACTOR,
    ORACLE_PRICE_SCALE
} from "../../src/review/libraries/ConstantsLib.sol";

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

contract MorphoBlueReviewTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant INITIAL_PRICE = 1e36;
    uint256 internal constant STARTING_BALANCE = 10_000 ether;
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    IMorpho internal morpho;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    FixedRateIrmReview internal irm;
    MutableOracleReview internal oracle;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal supplier = makeAddr("supplier");
    address internal secondSupplier = makeAddr("secondSupplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");
    address internal delegate = makeAddr("delegate");
    uint256 internal authorizerPk;
    address internal authorizer;

    MarketParams internal marketParams;
    Id internal marketId;

    function setUp() public {
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
        marketId = marketParams.id();

        morpho.createMarket(marketParams);

        _mintAndApprove(supplier, STARTING_BALANCE, STARTING_BALANCE);
        _mintAndApprove(secondSupplier, STARTING_BALANCE, STARTING_BALANCE);
        _mintAndApprove(borrower, STARTING_BALANCE, STARTING_BALANCE);
        _mintAndApprove(liquidator, STARTING_BALANCE, STARTING_BALANCE);
        _mintAndApprove(delegate, STARTING_BALANCE, STARTING_BALANCE);

        authorizerPk = 0xA11CE;
        authorizer = vm.addr(authorizerPk);
    }

    function test_Review_MarketIdentityMatchesCanonicalStoredParams() public {
        MarketParams memory stored = morpho.idToMarketParams(marketId);

        assertEq(stored.loanToken, marketParams.loanToken);
        assertEq(stored.collateralToken, marketParams.collateralToken);
        assertEq(stored.oracle, marketParams.oracle);
        assertEq(stored.irm, marketParams.irm);
        assertEq(stored.lltv, marketParams.lltv);

        MarketParams memory differentParams = marketParams;
        differentParams.oracle = address(new MutableOracleReview(INITIAL_PRICE));
        Id differentId = differentParams.id();
        Market memory differentMarket = morpho.market(differentId);

        assertTrue(Id.unwrap(differentId) != Id.unwrap(marketId));
        assertEq(differentMarket.lastUpdate, 0);
    }

    function test_Review_AccrualIncreasesAssetsButDoesNotMintSupplierShares() public {
        vm.prank(owner);
        morpho.setFee(marketParams, 0.1e18);

        _supply(supplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);
        _borrow(borrower, 700 ether);

        Position memory supplierBefore = morpho.position(marketId, supplier);
        Position memory feeRecipientBefore = morpho.position(marketId, feeRecipient);
        Market memory marketBefore = morpho.market(marketId);

        irm.setRatePerSecond(2e12);
        vm.warp(block.timestamp + 1 days);
        morpho.accrueInterest(marketParams);

        Position memory supplierAfter = morpho.position(marketId, supplier);
        Position memory feeRecipientAfter = morpho.position(marketId, feeRecipient);
        Market memory marketAfter = morpho.market(marketId);

        assertEq(supplierAfter.supplyShares, supplierBefore.supplyShares);
        assertEq(supplierAfter.borrowShares, supplierBefore.borrowShares);
        assertGt(feeRecipientAfter.supplyShares, feeRecipientBefore.supplyShares);
        assertEq(marketAfter.totalSupplyShares, marketBefore.totalSupplyShares + feeRecipientAfter.supplyShares);
        assertGt(marketAfter.totalSupplyAssets, marketBefore.totalSupplyAssets);
        assertGt(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets);
        _assertRecordedLiquidityBound();
    }

    function test_Review_VirtualSupplySharesCanLeavePartOfInterestOutsideRealSupplierClaim() public {
        _supply(supplier, 1 ether);
        _supplyCollateral(borrower, 10 ether);
        _borrow(borrower, 1 wei);

        Position memory supplierBefore = morpho.position(marketId, supplier);
        Market memory marketBefore = morpho.market(marketId);
        uint256 supplierClaimBefore =
            _toAssetsDown(supplierBefore.supplyShares, marketBefore.totalSupplyAssets, marketBefore.totalSupplyShares);

        irm.setRatePerSecond(1e16);
        vm.warp(block.timestamp + 1 days);
        morpho.accrueInterest(marketParams);

        Position memory supplierAfter = morpho.position(marketId, supplier);
        Market memory marketAfter = morpho.market(marketId);
        uint256 supplierClaimAfter =
            _toAssetsDown(supplierAfter.supplyShares, marketAfter.totalSupplyAssets, marketAfter.totalSupplyShares);

        uint256 marketGrowth = marketAfter.totalSupplyAssets - marketBefore.totalSupplyAssets;
        uint256 supplierGrowth = supplierClaimAfter - supplierClaimBefore;

        assertGt(marketGrowth, 0);
        assertLt(supplierGrowth, marketGrowth);
    }

    function test_Review_AccruedInterestAloneCanMakeBorrowerLiquidatable() public {
        _supply(supplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);
        _borrow(borrower, 700 ether);

        Position memory beforeAccrual = morpho.position(marketId, borrower);

        vm.expectRevert(bytes(ErrorsLib.HEALTHY_POSITION));
        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 1 ether, 0, "");

        irm.setRatePerSecond(3e12);
        vm.warp(block.timestamp + 1 days);

        Position memory beforeTriggeredLiquidation = morpho.position(marketId, borrower);
        assertEq(beforeTriggeredLiquidation.borrowShares, beforeAccrual.borrowShares);
        assertEq(beforeTriggeredLiquidation.collateral, beforeAccrual.collateral);

        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 1 ether, 0, "");

        Position memory afterLiquidation = morpho.position(marketId, borrower);
        assertLt(afterLiquidation.borrowShares, beforeAccrual.borrowShares);
        assertLt(afterLiquidation.collateral, beforeAccrual.collateral);
        _assertRecordedLiquidityBound();
    }

    function test_Review_BorrowAndWithdrawCollateralRevertWhenTheyWouldLeavePositionUnhealthy() public {
        _supply(supplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);

        vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
        vm.prank(borrower);
        morpho.borrow(marketParams, 801 ether, 0, borrower, borrower);

        _borrow(borrower, 700 ether);

        vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
        vm.prank(borrower);
        morpho.withdrawCollateral(marketParams, 200 ether, borrower, borrower);
    }

    function test_Review_RecordedLiquidityBoundHoldsAcrossBorrowAccrueRepayAndLiquidation() public {
        _supply(supplier, 1_500 ether);
        _supplyCollateral(borrower, 1_000 ether);
        _borrow(borrower, 800 ether);
        _assertRecordedLiquidityBound();

        irm.setRatePerSecond(1e12);
        vm.warp(block.timestamp + 1 days);
        morpho.accrueInterest(marketParams);
        _assertRecordedLiquidityBound();

        vm.prank(borrower);
        morpho.repay(marketParams, 200 ether, 0, borrower, "");
        _assertRecordedLiquidityBound();

        oracle.setPrice(0.6e36);
        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 100 ether, 0, "");
        _assertRecordedLiquidityBound();
    }

    function test_Review_HealthyPositionCannotBeLiquidated() public {
        _supply(supplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);
        _borrow(borrower, 500 ether);

        vm.expectRevert(bytes(ErrorsLib.HEALTHY_POSITION));
        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 10 ether, 0, "");
    }

    function test_Review_LiquidationIncentiveFactorIsBoundedAndNonIncreasingAcrossLLTVs() public pure {
        uint256 low = _liquidationIncentiveFactor(0.5e18);
        uint256 mid = _liquidationIncentiveFactor(0.8e18);
        uint256 high = _liquidationIncentiveFactor(0.95e18);
        uint256 nearMax = _liquidationIncentiveFactor(0.999e18);

        assertGe(low, WAD);
        assertLe(mid, low);
        assertLe(high, mid);
        assertLe(nearMax, high);

        assertLe(low, MAX_LIQUIDATION_INCENTIVE_FACTOR);
        assertLe(mid, MAX_LIQUIDATION_INCENTIVE_FACTOR);
        assertLe(high, MAX_LIQUIDATION_INCENTIVE_FACTOR);
        assertLe(nearMax, MAX_LIQUIDATION_INCENTIVE_FACTOR);
    }

    function test_Review_RoundingPolicy_FavorsProtocolOnSupplyWithdrawAndBorrowRepay() public {
        _supply(supplier, 10 ether);
        _supplyCollateral(borrower, 10 ether);
        _borrow(borrower, 3 ether);

        Market memory marketBeforeWithdraw = morpho.market(marketId);
        uint256 expectedBurnedShares = _toSharesUp(1 wei, marketBeforeWithdraw.totalSupplyAssets, marketBeforeWithdraw.totalSupplyShares);
        vm.prank(supplier);
        (uint256 withdrawnAssets, uint256 burnedShares) = morpho.withdraw(marketParams, 1 wei, 0, supplier, supplier);
        assertEq(withdrawnAssets, 1 wei);
        assertEq(burnedShares, expectedBurnedShares);

        Market memory marketBeforeRepay = morpho.market(marketId);
        uint256 expectedRepaidShares = _toSharesDown(1 wei, marketBeforeRepay.totalBorrowAssets, marketBeforeRepay.totalBorrowShares);
        vm.prank(borrower);
        (uint256 repaidAssets, uint256 burnedBorrowShares) = morpho.repay(marketParams, 1 wei, 0, borrower, "");
        assertEq(repaidAssets, 1 wei);
        assertEq(burnedBorrowShares, expectedRepaidShares);

        _supply(supplier, 1 wei);
        _borrow(borrower, 1 wei);

        Position memory supplierPosition = morpho.position(marketId, supplier);
        Position memory borrowerPosition = morpho.position(marketId, borrower);
        Market memory current = morpho.market(marketId);

        assertGt(supplierPosition.supplyShares, 0);
        assertGt(borrowerPosition.borrowShares, 0);
        assertLe(current.totalBorrowAssets, current.totalSupplyAssets);
    }

    function test_Review_SupplyCallbackRevertRollsBackAccounting() public {
        RevertingSupplyCallback callback = new RevertingSupplyCallback(morpho, marketParams);
        loanToken.mint(address(callback), 100 ether);

        vm.prank(address(callback));
        loanToken.approve(address(morpho), type(uint256).max);

        Market memory marketBefore = morpho.market(marketId);
        Position memory positionBefore = morpho.position(marketId, borrower);

        vm.expectRevert(bytes("callback revert"));
        callback.run(100 ether, borrower);

        Market memory marketAfter = morpho.market(marketId);
        Position memory positionAfter = morpho.position(marketId, borrower);

        assertEq(marketAfter.totalSupplyAssets, marketBefore.totalSupplyAssets);
        assertEq(marketAfter.totalSupplyShares, marketBefore.totalSupplyShares);
        assertEq(positionAfter.supplyShares, positionBefore.supplyShares);
        assertEq(loanToken.balanceOf(address(callback)), 100 ether);
    }

    function test_Review_SetAuthorizationWithSig_ValidThenReplayAndExpiredFail() public {
        Authorization memory authorization = Authorization({
            authorizer: authorizer,
            authorized: delegate,
            isAuthorized: true,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        Signature memory signature = _signAuthorization(authorization, authorizerPk);
        morpho.setAuthorizationWithSig(authorization, signature);

        assertTrue(morpho.isAuthorized(authorizer, delegate));
        assertEq(morpho.nonce(authorizer), 1);

        vm.expectRevert(bytes(ErrorsLib.INVALID_NONCE));
        morpho.setAuthorizationWithSig(authorization, signature);

        Authorization memory expiredAuthorization = Authorization({
            authorizer: authorizer,
            authorized: delegate,
            isAuthorized: false,
            nonce: 1,
            deadline: block.timestamp - 1
        });
        Signature memory expiredSignature = _signAuthorization(expiredAuthorization, authorizerPk);

        vm.expectRevert(bytes(ErrorsLib.SIGNATURE_EXPIRED));
        morpho.setAuthorizationWithSig(expiredAuthorization, expiredSignature);
    }

    function test_Review_SetAuthorizationWithSig_InvalidSignerAndTamperedFieldsFail() public {
        Authorization memory authorization = Authorization({
            authorizer: authorizer,
            authorized: delegate,
            isAuthorized: true,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        Signature memory wrongSignerSignature = _signAuthorization(authorization, 0xB0B);
        vm.expectRevert(bytes(ErrorsLib.INVALID_SIGNATURE));
        morpho.setAuthorizationWithSig(authorization, wrongSignerSignature);

        Signature memory validSignature = _signAuthorization(authorization, authorizerPk);

        Authorization memory wrongDelegateAuthorization = Authorization({
            authorizer: authorizer,
            authorized: supplier,
            isAuthorized: true,
            nonce: 0,
            deadline: authorization.deadline
        });
        vm.expectRevert(bytes(ErrorsLib.INVALID_SIGNATURE));
        morpho.setAuthorizationWithSig(wrongDelegateAuthorization, validSignature);

        address otherAuthorizer = makeAddr("otherAuthorizer");
        Authorization memory wrongAuthorizerAuthorization = Authorization({
            authorizer: otherAuthorizer,
            authorized: delegate,
            isAuthorized: true,
            nonce: 0,
            deadline: authorization.deadline
        });
        vm.expectRevert(bytes(ErrorsLib.INVALID_SIGNATURE));
        morpho.setAuthorizationWithSig(wrongAuthorizerAuthorization, validSignature);
    }

    function test_Review_FullCollateralExhaustionCrystallizesBadDebt() public {
        _supply(supplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);
        _borrow(borrower, 700 ether);

        oracle.setPrice(0.5e36);

        Market memory marketBefore = morpho.market(marketId);

        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 1_000 ether, 0, "");

        Position memory borrowerAfter = morpho.position(marketId, borrower);
        Market memory marketAfter = morpho.market(marketId);

        assertEq(borrowerAfter.collateral, 0);
        assertEq(borrowerAfter.borrowShares, 0);
        assertLt(marketAfter.totalSupplyAssets, marketBefore.totalSupplyAssets);
        assertLt(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets);
        _assertRecordedLiquidityBound();
    }

    function test_Review_BadDebtSocializationCanBeDelayedByLeavingOneWeiCollateral() public {
        _supply(supplier, 1_000 ether);
        _supply(secondSupplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);
        _borrow(borrower, 800 ether);

        oracle.setPrice(0.5e36);

        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 1_000 ether - 1, 0, "");

        Position memory borrowerAfterPartial = morpho.position(marketId, borrower);
        Market memory marketAfterPartial = morpho.market(marketId);

        assertEq(borrowerAfterPartial.collateral, 1);
        assertGt(borrowerAfterPartial.borrowShares, 0);
        assertEq(marketAfterPartial.totalSupplyAssets, 2_000 ether);

        vm.prank(supplier);
        morpho.withdraw(marketParams, 1_000 ether, 0, supplier, supplier);

        Market memory marketAfterExit = morpho.market(marketId);
        assertEq(marketAfterExit.totalSupplyAssets, 1_000 ether);

        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 1, 0, "");

        Position memory borrowerAfterFinal = morpho.position(marketId, borrower);
        Market memory marketAfterFinal = morpho.market(marketId);

        assertEq(borrowerAfterFinal.collateral, 0);
        assertEq(borrowerAfterFinal.borrowShares, 0);
        assertLt(marketAfterFinal.totalSupplyAssets, marketAfterExit.totalSupplyAssets);
        assertEq(marketAfterFinal.totalSupplyAssets < 1_000 ether, true);
        _assertRecordedLiquidityBound();
    }

    function test_Review_LiquidationMustNotSocializePhantomBadDebtWhenResidualBorrowSharesAreZero() public {
        _supply(supplier, 100 ether);
        _supplyCollateral(borrower, 2 wei);
        _borrow(borrower, 1 wei);

        oracle.setPrice(0.5e36);

        Position memory borrowerBefore = morpho.position(marketId, borrower);
        Market memory marketBefore = morpho.market(marketId);
        assertGt(borrowerBefore.borrowShares, 0);

        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 0, borrowerBefore.borrowShares, "");

        Position memory borrowerAfter = morpho.position(marketId, borrower);
        Market memory marketAfter = morpho.market(marketId);

        assertEq(borrowerAfter.borrowShares, 0);
        assertEq(borrowerAfter.collateral, 0);
        assertEq(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets - 1);
        assertEq(marketAfter.totalBorrowShares, marketBefore.totalBorrowShares - borrowerBefore.borrowShares);
        assertEq(marketAfter.totalSupplyAssets, marketBefore.totalSupplyAssets);
        _assertRecordedLiquidityBound();
    }

    function test_Review_VirtualBorrowSharesCanLeaveResidualDebtThatReducesWithdrawability() public {
        _supply(supplier, 100 ether);
        _supplyCollateral(borrower, 2 wei);
        _borrow(borrower, 1 wei);

        Position memory borrowerBefore = morpho.position(marketId, borrower);
        vm.prank(borrower);
        morpho.repay(marketParams, 0, borrowerBefore.borrowShares, borrower, "");

        Position memory borrowerAfter = morpho.position(marketId, borrower);
        Market memory marketAfterRepay = morpho.market(marketId);

        assertEq(borrowerAfter.borrowShares, 0);

        if (marketAfterRepay.totalBorrowAssets > 0) {
            vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_LIQUIDITY));
            vm.prank(supplier);
            morpho.withdraw(marketParams, 100 ether, 0, supplier, supplier);
        }
    }

    function test_Review_USDCLikeSixDecimalLoanToken_HealthLiquidationAndRoundingRemainCoherent() public {
        MockERC20 usdcLike = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 collateral18 = new MockERC20("Collateral", "COLL", 18);
        MutableOracleReview mixedDecimalsOracle = new MutableOracleReview(1e24);
        FixedRateIrmReview localIrm = new FixedRateIrmReview(0);

        vm.prank(owner);
        IMorpho localMorpho = IMorpho(address(new Morpho(owner)));

        vm.startPrank(owner);
        localMorpho.enableIrm(address(localIrm));
        localMorpho.enableLltv(LLTV);
        localMorpho.setFeeRecipient(feeRecipient);
        vm.stopPrank();

        MarketParams memory usdcMarketParams = MarketParams({
            loanToken: address(usdcLike),
            collateralToken: address(collateral18),
            oracle: address(mixedDecimalsOracle),
            irm: address(localIrm),
            lltv: LLTV
        });
        Id usdcMarketId = usdcMarketParams.id();

        localMorpho.createMarket(usdcMarketParams);

        _mintAndApproveFor(localMorpho, usdcLike, collateral18, supplier, 10_000e6, 0);
        _mintAndApproveFor(localMorpho, usdcLike, collateral18, borrower, 10_000e6, 10_000 ether);
        _mintAndApproveFor(localMorpho, usdcLike, collateral18, liquidator, 10_000e6, 0);

        vm.prank(supplier);
        localMorpho.supply(usdcMarketParams, 2_000e6, 0, supplier, "");

        vm.prank(borrower);
        localMorpho.supplyCollateral(usdcMarketParams, 2_000 ether, borrower, "");

        vm.prank(borrower);
        localMorpho.borrow(usdcMarketParams, 1_500e6, 0, borrower, borrower);

        Position memory borrowerBefore = localMorpho.position(usdcMarketId, borrower);
        Market memory marketBefore = localMorpho.market(usdcMarketId);

        vm.expectRevert(bytes(ErrorsLib.INSUFFICIENT_COLLATERAL));
        vm.prank(borrower);
        localMorpho.withdrawCollateral(usdcMarketParams, 200 ether, borrower, borrower);

        vm.prank(borrower);
        (uint256 repaidAssets, uint256 burnedBorrowShares) = localMorpho.repay(usdcMarketParams, 1, 0, borrower, "");
        assertEq(repaidAssets, 1);
        assertGt(burnedBorrowShares, 0);

        mixedDecimalsOracle.setPrice(9e23);

        vm.prank(liquidator);
        localMorpho.liquidate(usdcMarketParams, borrower, 1 ether, 0, "");

        Position memory borrowerAfter = localMorpho.position(usdcMarketId, borrower);
        Market memory marketAfter = localMorpho.market(usdcMarketId);

        assertLt(borrowerAfter.borrowShares, borrowerBefore.borrowShares);
        assertLt(borrowerAfter.collateral, borrowerBefore.collateral);
        assertLe(marketAfter.totalBorrowAssets, marketAfter.totalSupplyAssets);
        assertEq(usdcLike.decimals(), 6);
        assertEq(collateral18.decimals(), 18);
        assertGt(marketBefore.totalBorrowAssets, marketAfter.totalBorrowAssets);
    }

    function test_Review_TinyLiquidation_SeizedAssetsBranch_DoesNotWorsenBorrowerHealthPerUnitDebtReduction() public {
        _supply(supplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);
        _borrow(borrower, 790 ether);

        oracle.setPrice(0.98e36);

        (uint256 debtBefore, uint256 maxBorrowBefore) = _borrowerDebtAndMaxBorrow();

        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 1 wei, 0, "");

        (uint256 debtAfter, uint256 maxBorrowAfter) = _borrowerDebtAndMaxBorrow();

        assertLe(debtAfter, debtBefore);
        assertLt(maxBorrowAfter, maxBorrowBefore);
        assertLe(_healthShortfall(debtAfter, maxBorrowAfter), _healthShortfall(debtBefore, maxBorrowBefore));
    }

    function test_Review_TinyLiquidation_RepaidSharesBranch_CannotSeizeCollateralForZeroDebtReduction() public {
        _supply(supplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);
        _borrow(borrower, 790 ether);

        oracle.setPrice(0.98e36);

        Position memory positionBefore = morpho.position(marketId, borrower);
        Market memory marketBefore = morpho.market(marketId);

        vm.prank(liquidator);
        morpho.liquidate(marketParams, borrower, 0, 1, "");

        Position memory positionAfter = morpho.position(marketId, borrower);
        Market memory marketAfter = morpho.market(marketId);

        assertLt(positionAfter.borrowShares, positionBefore.borrowShares);
        assertLt(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets);
        assertLt(marketAfter.totalBorrowShares, marketBefore.totalBorrowShares);
        if (positionAfter.collateral < positionBefore.collateral) {
            assertLt(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets);
            assertLt(positionAfter.borrowShares, positionBefore.borrowShares);
        }
    }

    function test_Review_RepeatedDustLiquidations_CannotStripCollateralWhileBarelyReducingDebt() public {
        _supply(supplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);
        _borrow(borrower, 790 ether);

        oracle.setPrice(0.98e36);

        Position memory start = morpho.position(marketId, borrower);
        uint256 startDebtAssets = morpho.market(marketId).totalBorrowAssets;

        for (uint256 i = 0; i < 10; ++i) {
            vm.prank(liquidator);
            morpho.liquidate(marketParams, borrower, 1 wei, 0, "");
        }

        Position memory end = morpho.position(marketId, borrower);
        uint256 endDebtAssets = morpho.market(marketId).totalBorrowAssets;

        assertLe(start.collateral - end.collateral, startDebtAssets - endDebtAssets);
        assertLt(end.borrowShares, start.borrowShares);
        assertLt(end.collateral, start.collateral);
    }

    function test_Review_AuthorizationControlsDelegatedBorrowAndCollateralWithdraw() public {
        _supply(supplier, 1_000 ether);
        _supplyCollateral(borrower, 1_000 ether);

        vm.expectRevert(bytes(ErrorsLib.UNAUTHORIZED));
        vm.prank(delegate);
        morpho.borrow(marketParams, 100 ether, 0, borrower, delegate);

        vm.prank(borrower);
        morpho.setAuthorization(delegate, true);

        vm.prank(delegate);
        morpho.borrow(marketParams, 100 ether, 0, borrower, delegate);

        vm.prank(delegate);
        morpho.withdrawCollateral(marketParams, 100 ether, borrower, delegate);

        Position memory delegatedPosition = morpho.position(marketId, borrower);
        assertEq(delegatedPosition.borrowShares > 0, true);
        assertEq(delegatedPosition.collateral, 900 ether);
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

    function _supply(address user, uint256 assets) internal {
        vm.prank(user);
        morpho.supply(marketParams, assets, 0, user, "");
    }

    function _supplyCollateral(address user, uint256 assets) internal {
        vm.prank(user);
        morpho.supplyCollateral(marketParams, assets, user, "");
    }

    function _borrow(address user, uint256 assets) internal {
        vm.prank(user);
        morpho.borrow(marketParams, assets, 0, user, user);
    }

    function _assertRecordedLiquidityBound() internal view {
        Market memory current = morpho.market(marketId);
        assertLe(current.totalBorrowAssets, current.totalSupplyAssets);
    }

    function _borrowerDebtAndMaxBorrow() internal view returns (uint256 debt, uint256 maxBorrow) {
        Position memory currentPosition = morpho.position(marketId, borrower);
        Market memory currentMarket = morpho.market(marketId);
        uint256 collateralPrice = oracle.price();

        debt = _toAssetsUp(currentPosition.borrowShares, currentMarket.totalBorrowAssets, currentMarket.totalBorrowShares);
        maxBorrow = (uint256(currentPosition.collateral) * collateralPrice / ORACLE_PRICE_SCALE) * LLTV / WAD;
    }

    function _healthShortfall(uint256 debt, uint256 maxBorrow) internal pure returns (uint256) {
        return debt > maxBorrow ? debt - maxBorrow : 0;
    }

    function _signAuthorization(Authorization memory authorization, uint256 privateKey)
        internal
        view
        returns (Signature memory)
    {
        bytes32 hashStruct = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", morpho.DOMAIN_SEPARATOR(), hashStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return Signature({v: v, r: r, s: s});
    }

    function _liquidationIncentiveFactor(uint256 lltv) internal pure returns (uint256) {
        uint256 denominator = WAD - ((LIQUIDATION_CURSOR * (WAD - lltv)) / WAD);
        uint256 uncapped = (WAD * WAD) / denominator;
        return uncapped < MAX_LIQUIDATION_INCENTIVE_FACTOR ? uncapped : MAX_LIQUIDATION_INCENTIVE_FACTOR;
    }

    function _toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return (assets * (totalShares + VIRTUAL_SHARES)) / (totalAssets + VIRTUAL_ASSETS);
    }

    function _toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        uint256 numerator = assets * (totalShares + VIRTUAL_SHARES);
        uint256 denominator = totalAssets + VIRTUAL_ASSETS;
        return (numerator + (denominator - 1)) / denominator;
    }

    function _toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        uint256 numerator = shares * (totalAssets + VIRTUAL_ASSETS);
        uint256 denominator = totalShares + VIRTUAL_SHARES;
        return (numerator + (denominator - 1)) / denominator;
    }

    function _toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return (shares * (totalAssets + VIRTUAL_ASSETS)) / (totalShares + VIRTUAL_SHARES);
    }
}
