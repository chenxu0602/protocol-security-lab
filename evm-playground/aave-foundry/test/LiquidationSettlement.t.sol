// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Test} from "forge-std/Test.sol";

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IAToken} from "@aave/core-v3/contracts/interfaces/IAToken.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";
import {IERC20} from "@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from "@aave/core-v3/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {PercentageMath} from "@aave/core-v3/contracts/protocol/libraries/math/PercentageMath.sol";

interface IOwnableLike {
    function owner() external view returns (address);
}

contract MockPriceOracle is IPriceOracleGetter {
    mapping(address => uint256) internal prices;

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getAssetPrice(address asset) external view override returns (uint256) {
        uint256 price = prices[asset];
        require(price != 0, "missing price");
        return price;
    }

    function BASE_CURRENCY() external pure returns (address) {
        return address(0);
    }

    function BASE_CURRENCY_UNIT() external pure returns (uint256) {
        return 1e8;
    }
}

contract LiquidationSettlementTest is Test {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using PercentageMath for uint256;

    IPool internal constant POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    address internal constant COLLATERAL_ASSET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address internal constant DEBT_ASSET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC

    uint256 internal constant FORK_BLOCK = 19_000_000;
    uint256 internal constant BASE_PRICE = 1e8;
    uint256 internal constant COLLATERAL_AMOUNT = 100 ether;

    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockPriceOracle internal oracle;

    struct Snapshot {
        uint256 debt;
        uint256 userCollateral;
        uint256 liquidatorCollateral;
        uint256 treasuryCollateral;
        uint256 liquidatorDebtAssets;
    }

    struct ExpectedSettlement {
        uint256 collateralToLiquidator;
        uint256 debtBurn;
        uint256 protocolFee;
    }

    struct LiquidationCalcCtx {
        uint256 collateralPrice;
        uint256 debtPrice;
        uint256 collateralUnit;
        uint256 debtUnit;
        uint256 liquidationBonus;
        uint256 liquidationProtocolFee;
        uint256 grossCollateral;
        uint256 bonusCollateral;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

        IPoolAddressesProvider provider = POOL.ADDRESSES_PROVIDER();
        oracle = new MockPriceOracle();
        oracle.setPrice(COLLATERAL_ASSET, BASE_PRICE);
        oracle.setPrice(DEBT_ASSET, BASE_PRICE);

        vm.prank(IOwnableLike(address(provider)).owner());
        provider.setPriceOracle(address(oracle));

        _openPosition();
        _pushBorrowerBelowHFOne();
    }

    function _openPosition() internal {
        DataTypes.ReserveData memory collateralReserve = POOL.getReserveData(COLLATERAL_ASSET);
        uint256 collateralDecimals = collateralReserve.configuration.getDecimals();
        uint256 debtDecimals = POOL.getReserveData(DEBT_ASSET).configuration.getDecimals();
        uint256 ltv = collateralReserve.configuration.getLtv();

        uint256 maxBorrow =
            (((COLLATERAL_AMOUNT * BASE_PRICE) / (10 ** collateralDecimals)) * ltv / 10_000)
                * (10 ** debtDecimals) / BASE_PRICE;

        uint256 borrowAmount = (maxBorrow * 95) / 100;

        deal(COLLATERAL_ASSET, borrower, COLLATERAL_AMOUNT);

        vm.startPrank(borrower);
        IERC20(COLLATERAL_ASSET).approve(address(POOL), type(uint256).max);
        POOL.supply(COLLATERAL_ASSET, COLLATERAL_AMOUNT, borrower, 0);
        POOL.borrow(DEBT_ASSET, borrowAmount, 2, 0, borrower); // variable rate
        vm.stopPrank();
    }

    function _pushBorrowerBelowHFOne() internal {
        uint256 boundary = _collateralPriceForHFOne();
        oracle.setPrice(COLLATERAL_ASSET, boundary - 1);

        (, , , , , uint256 hf) = POOL.getUserAccountData(borrower);
        assertLt(hf, 1e18, "HF should be just below 1");
        assertGt(hf, 0.95e18, "keeps 50% close-factor branch for easier accounting");
    }

    function _collateralPriceForHFOne() internal view returns (uint256) {
        DataTypes.ReserveData memory collateralReserve = POOL.getReserveData(COLLATERAL_ASSET);
        DataTypes.ReserveData memory debtReserve = POOL.getReserveData(DEBT_ASSET);

        uint256 liquidationThreshold = collateralReserve.configuration.getLiquidationThreshold();
        uint256 collateralDecimals = collateralReserve.configuration.getDecimals();
        uint256 debtDecimals = debtReserve.configuration.getDecimals();

        uint256 collateralBalance = IAToken(collateralReserve.aTokenAddress).balanceOf(borrower);
        uint256 debtBalance = IERC20(debtReserve.variableDebtTokenAddress).balanceOf(borrower);
        uint256 debtPrice = oracle.getAssetPrice(DEBT_ASSET);

        require(debtBalance != 0, "debt balance is zero");

        return (
            debtPrice * debtBalance * (10 ** collateralDecimals) * 10_000
                + (collateralBalance * (10 ** debtDecimals) * liquidationThreshold) - 1
        ) / (collateralBalance * (10 ** debtDecimals) * liquidationThreshold);
    }

    function _calculateExpectedLiquidation(uint256 debtToCover, uint256 userCollateralBalance)
        internal
        view
        returns (ExpectedSettlement memory e)
    {
        DataTypes.ReserveData memory collateralReserve = POOL.getReserveData(COLLATERAL_ASSET);
        DataTypes.ReserveData memory debtReserve = POOL.getReserveData(DEBT_ASSET);

        LiquidationCalcCtx memory c;
        c.collateralPrice = oracle.getAssetPrice(COLLATERAL_ASSET);
        c.debtPrice = oracle.getAssetPrice(DEBT_ASSET);
        c.collateralUnit = 10 ** collateralReserve.configuration.getDecimals();
        c.debtUnit = 10 ** debtReserve.configuration.getDecimals();
        c.liquidationBonus = collateralReserve.configuration.getLiquidationBonus();
        c.liquidationProtocolFee = collateralReserve.configuration.getLiquidationProtocolFee();

        uint256 baseCollateral =
            (c.debtPrice * debtToCover * c.collateralUnit) / (c.collateralPrice * c.debtUnit);
        uint256 maxCollateralToLiquidate = baseCollateral.percentMul(c.liquidationBonus);

        if (maxCollateralToLiquidate > userCollateralBalance) {
            c.grossCollateral = userCollateralBalance;
            e.debtBurn = (
                (c.collateralPrice * c.grossCollateral * c.debtUnit) /
                (c.debtPrice * c.collateralUnit)
            ).percentDiv(c.liquidationBonus);
        } else {
            c.grossCollateral = maxCollateralToLiquidate;
            e.debtBurn = debtToCover;
        }

        c.bonusCollateral = c.grossCollateral - c.grossCollateral.percentDiv(c.liquidationBonus);
        e.protocolFee = c.bonusCollateral.percentMul(c.liquidationProtocolFee);
        e.collateralToLiquidator = c.grossCollateral - e.protocolFee;
    }

    function _snapshot(address collateralAToken, address debtToken, address treasury)
        internal
        view
        returns (Snapshot memory s)
    {
        s.debt = IERC20(debtToken).balanceOf(borrower);
        s.userCollateral = IAToken(collateralAToken).balanceOf(borrower);
        s.liquidatorCollateral = IAToken(collateralAToken).balanceOf(liquidator);
        s.treasuryCollateral = IAToken(collateralAToken).balanceOf(treasury);
        s.liquidatorDebtAssets = IERC20(DEBT_ASSET).balanceOf(liquidator);
    }

    function test_LiquidationSettlement_RemainsValueCoherent() public {
        DataTypes.ReserveData memory collateralReserve = POOL.getReserveData(COLLATERAL_ASSET);
        DataTypes.ReserveData memory debtReserve = POOL.getReserveData(DEBT_ASSET);

        address collateralAToken = collateralReserve.aTokenAddress;
        address debtToken = debtReserve.variableDebtTokenAddress;
        address treasury = IAToken(collateralAToken).RESERVE_TREASURY_ADDRESS();

        Snapshot memory beforeSnap = _snapshot(collateralAToken, debtToken, treasury);

        uint256 debtToCover = beforeSnap.debt / 4;
        ExpectedSettlement memory expected =
            _calculateExpectedLiquidation(debtToCover, beforeSnap.userCollateral);


        deal(DEBT_ASSET, liquidator, expected.debtBurn);

        uint256 liquidatorDebtAssetsBeforeCall = IERC20(DEBT_ASSET).balanceOf(liquidator);

        vm.prank(liquidator);
        IERC20(DEBT_ASSET).approve(address(POOL), type(uint256).max);

        vm.prank(liquidator);
        POOL.liquidationCall(COLLATERAL_ASSET, DEBT_ASSET, borrower, debtToCover, true);

        Snapshot memory afterSnap = _snapshot(collateralAToken, debtToken, treasury);

        uint256 actualDebtBurn = beforeSnap.debt - afterSnap.debt;
        uint256 actualLiquidatorSeize =
            afterSnap.liquidatorCollateral - beforeSnap.liquidatorCollateral;
        uint256 actualProtocolFee =
            afterSnap.treasuryCollateral - beforeSnap.treasuryCollateral;
        uint256 actualUserCollateralLoss =
            beforeSnap.userCollateral - afterSnap.userCollateral;
        uint256 actualLiquidatorSpend =
            liquidatorDebtAssetsBeforeCall - afterSnap.liquidatorDebtAssets;


        assertApproxEqAbs(
            actualDebtBurn,
            expected.debtBurn,
            2,
            "actual debt burn should match expected debt burn"
        );

        assertApproxEqAbs(
            actualLiquidatorSpend,
            expected.debtBurn,
            2,
            "liquidator spend mismatch"
        );

        assertApproxEqAbs(
            actualLiquidatorSeize,
            expected.collateralToLiquidator,
            2,
            "liquidator seize mismatch"
        );

        assertApproxEqAbs(
            actualProtocolFee,
            expected.protocolFee,
            2,
            "protocol fee mismatch"
        );

        assertEq(
            actualUserCollateralLoss,
            actualLiquidatorSeize + actualProtocolFee,
            "user collateral loss mismatch"
        );

        assertLe(
            actualLiquidatorSeize + actualProtocolFee,
            beforeSnap.userCollateral,
            "liquidator should not seize more than user collateral"
        );
    }
}