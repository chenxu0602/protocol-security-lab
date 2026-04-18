// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Test} from 'forge-std/Test.sol';

import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IAToken} from '@aave/core-v3/contracts/interfaces/IAToken.sol';
import {IPriceOracleGetter} from '@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '@aave/core-v3/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {Errors} from '@aave/core-v3/contracts/protocol/libraries/helpers/Errors.sol';


interface IOwnableLike {
    function owner() external view returns (address);
}

contract MockPriceOracle is IPriceOracleGetter {
    mapping(address => uint256) internal prices;

    function setPrice(address asset, uint256 price) public {
        prices[asset] = price;
    }

    function getAssetPrice(address asset) external view override returns (uint256) {
        uint256 price = prices[asset]; 
        require(price != 0, 'missing price');
        return price;
    }

    function BASE_CURRENCY() external pure returns (address) {
        return address(0);
    }

    function BASE_CURRENCY_UNIT() external pure returns (uint256) {
        return 1e8;
    }
}


contract HealthFactorBoundaryTest is Test {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    IPool internal constant POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    // TODO: 按你实际想测的市场改
    address internal constant COLLATERAL_ASSET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address internal constant DEBT_ASSET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC

    uint256 internal constant FORK_BLOCK = 19_000_000;
    uint256 internal constant BASE_PRICE = 1e8;
    uint256 internal constant COLLATERAL_AMOUNT = 100 ether;

    address internal borrower = makeAddr('borrower');
    address internal liquidator = makeAddr('liquidator');

    IPoolAddressesProvider internal provider;
    MockPriceOracle internal mockOracle;

    function setUp() public {
        vm.createSelectFork(vm.envString('MAINNET_RPC_URL'), FORK_BLOCK);

        provider = POOL.ADDRESSES_PROVIDER();
        mockOracle = new MockPriceOracle();
        mockOracle.setPrice(COLLATERAL_ASSET, BASE_PRICE);
        mockOracle.setPrice(DEBT_ASSET, BASE_PRICE);

        vm.prank(IOwnableLike(address(provider)).owner());
        provider.setPriceOracle(address(mockOracle));
    }

    function _fundAndApproveLiquidator(uint256 amount) internal {
        deal(DEBT_ASSET, liquidator, amount);

        vm.prank(liquidator);
        IERC20(DEBT_ASSET).approve(address(POOL), type(uint256).max);
    }

    function _collateralAToken() internal view returns (address) {
        return POOL.getReserveData(COLLATERAL_ASSET).aTokenAddress;
    }

    function _debtToken() internal view returns (address) {
        return POOL.getReserveData(DEBT_ASSET).variableDebtTokenAddress;
    }

    function _openPosition() internal {
        DataTypes.ReserveData memory collateralReserve = POOL.getReserveData(COLLATERAL_ASSET);
        uint256 collateralDecimals = collateralReserve.configuration.getDecimals();
        uint256 debtDecimals = POOL.getReserveData(DEBT_ASSET).configuration.getDecimals();
        uint256 ltv = collateralReserve.configuration.getLtv();

        uint256 maxBorrow = 
            (((COLLATERAL_AMOUNT * BASE_PRICE) / (10 ** collateralDecimals)) * ltv / 10_000) * (10 ** debtDecimals) / BASE_PRICE;


        deal(COLLATERAL_ASSET, borrower, COLLATERAL_AMOUNT);

        vm.startPrank(borrower);
        IERC20(COLLATERAL_ASSET).approve(address(POOL), type(uint256).max);
        POOL.supply(COLLATERAL_ASSET, COLLATERAL_AMOUNT, borrower, 0);
        POOL.borrow(DEBT_ASSET, maxBorrow, 2, 0, borrower);
        vm.stopPrank();
    }

    function _collateralPriceForHFOne(address user) internal view returns (uint256) {
        DataTypes.ReserveData memory collateralReserve = POOL.getReserveData(COLLATERAL_ASSET);
        DataTypes.ReserveData memory debtReserve = POOL.getReserveData(DEBT_ASSET);

        uint256 liquidationThreshold = collateralReserve.configuration.getLiquidationThreshold();
        uint256 collateralDecimals = collateralReserve.configuration.getDecimals();
        uint256 debtDecimals = debtReserve.configuration.getDecimals();

        uint256 collateralBalance = IAToken(collateralReserve.aTokenAddress).balanceOf(user);
        uint256 debtBalance = IERC20(debtReserve.variableDebtTokenAddress).balanceOf(user);
        uint256 debtPrice = mockOracle.getAssetPrice(DEBT_ASSET);

        require(debtBalance != 0, 'debt balance is zero');

        return (
            debtPrice * debtBalance * (10 ** collateralDecimals) * 10_000
              + (collateralBalance * (10 ** debtDecimals) * liquidationThreshold) - 1
        ) / (collateralBalance * (10 ** debtDecimals) * liquidationThreshold);
    }

    function test_HFJustAboveOne_LiquidationReverts() public {
        _openPosition();

        uint256 priceAtBoundary = _collateralPriceForHFOne(borrower);
        mockOracle.setPrice(COLLATERAL_ASSET, priceAtBoundary + 1);

        (,,,,, uint256 hf) = POOL.getUserAccountData(borrower);
        assertGt(hf, 1e18, 'HF should be just above 1');

        uint256 debtToCover = IERC20(_debtToken()).balanceOf(borrower) / 4;
        _fundAndApproveLiquidator(debtToCover);

        vm.prank(liquidator);
        vm.expectRevert(bytes(Errors.HEALTH_FACTOR_NOT_BELOW_THRESHOLD));
        POOL.liquidationCall(COLLATERAL_ASSET, DEBT_ASSET, borrower, debtToCover, true);
    }

    function test_HFJustBelowOne_LiquidationSucceeds() public {
        _openPosition();

        uint256 priceAtBoundary = _collateralPriceForHFOne(borrower);
        mockOracle.setPrice(COLLATERAL_ASSET, priceAtBoundary - 1);

        (,,,,, uint256 hf) = POOL.getUserAccountData(borrower);
        assertLt(hf, 1e18, 'HF should be just below 1');

        uint256 borrowerDebtBefore = IERC20(_debtToken()).balanceOf(borrower);

        address collateralAToken = _collateralAToken();
        uint256 debtToCover = IERC20(_debtToken()).balanceOf(borrower) / 4;

        _fundAndApproveLiquidator(debtToCover);

        uint256 liquidatorCollateralBefore = IERC20(collateralAToken).balanceOf(liquidator);

        vm.prank(liquidator);
        POOL.liquidationCall(COLLATERAL_ASSET, DEBT_ASSET, borrower, debtToCover, true);

        uint256 liquidatorCollateralAfter = IERC20(collateralAToken).balanceOf(liquidator);
        uint256 borrowerDebtAfter = IERC20(_debtToken()).balanceOf(borrower);

        assertGt(liquidatorCollateralAfter, liquidatorCollateralBefore, 'liquidation should transfer collateral');
        assertLt(borrowerDebtAfter, borrowerDebtBefore, 'liquidation should transfer debt');

    }
}