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

contract RepayParityTest is Test {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    IPool internal constant POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    address internal constant COLLATERAL_ASSET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address internal constant DEBT_ASSET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC

    uint256 internal constant FORK_BLOCK = 19_000_000;
    uint256 internal constant BASE_PRICE = 1e8;
    uint256 internal constant COLLATERAL_AMOUNT = 100 ether;

    address internal borrowerUnderlying = makeAddr("borrowerUnderlying");
    address internal borrowerATokens = makeAddr("borrowerATokens");

    struct Snapshot {
        uint256 debt;
        uint256 reserveCash;
        uint256 aTokenSupply;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

        IPoolAddressesProvider provider = POOL.ADDRESSES_PROVIDER();
        MockPriceOracle oracle = new MockPriceOracle();
        oracle.setPrice(COLLATERAL_ASSET, BASE_PRICE);
        oracle.setPrice(DEBT_ASSET, BASE_PRICE);

        vm.prank(IOwnableLike(address(provider)).owner());
        provider.setPriceOracle(address(oracle));
    }

    function test_RepayUnderlying_And_RepayWithATokens_AreEconomicallyCoherent() public {
        uint256 debtOpened = _openMatchingPosition(borrowerUnderlying);
        _openMatchingPosition(borrowerATokens);

        uint256 repayAmount = debtOpened / 3;

        DataTypes.ReserveData memory debtReserve = POOL.getReserveData(DEBT_ASSET);
        address debtAToken = debtReserve.aTokenAddress;
        address variableDebtToken = debtReserve.variableDebtTokenAddress;

        // Give borrowerATokens enough underlying, then resupply it so they actually hold aTokens to burn.
        deal(DEBT_ASSET, borrowerATokens, repayAmount);
        vm.startPrank(borrowerATokens);
        IERC20(DEBT_ASSET).approve(address(POOL), type(uint256).max);
        POOL.supply(DEBT_ASSET, repayAmount, borrowerATokens, 0);
        vm.stopPrank();

        Snapshot memory beforeUnderlying = _snapshot(borrowerUnderlying, variableDebtToken, debtAToken);
        _repayUsingUnderlying(borrowerUnderlying, repayAmount);
        Snapshot memory afterUnderlying = _snapshot(borrowerUnderlying, variableDebtToken, debtAToken);

        Snapshot memory beforeATokens = _snapshot(borrowerATokens, variableDebtToken, debtAToken);
        _repayUsingATokens(borrowerATokens, repayAmount);
        Snapshot memory afterATokens = _snapshot(borrowerATokens, variableDebtToken, debtAToken);

        uint256 debtReductionUnderlying = beforeUnderlying.debt - afterUnderlying.debt;
        uint256 reserveCashDeltaUnderlying = afterUnderlying.reserveCash - beforeUnderlying.reserveCash;
        uint256 aTokenSupplyDeltaUnderlying = _absDiff(beforeUnderlying.aTokenSupply, afterUnderlying.aTokenSupply);

        uint256 debtReductionATokens = beforeATokens.debt - afterATokens.debt;
        uint256 reserveCashDeltaATokens = afterATokens.reserveCash - beforeATokens.reserveCash;
        uint256 aTokenSupplyDeltaATokens = _absDiff(beforeATokens.aTokenSupply, afterATokens.aTokenSupply);

        assertApproxEqAbs(debtReductionUnderlying, debtReductionATokens, 2, "debt reduction should match across repay paths");
        assertApproxEqAbs(reserveCashDeltaUnderlying, debtReductionUnderlying, 2, "underlying repay should add reserve cash equal to burned debt");
        assertLe(aTokenSupplyDeltaUnderlying, 2, "repay-with-underlying should not materially move debt reserve aToken supply");
        assertApproxEqAbs(aTokenSupplyDeltaATokens, repayAmount, 2, "repayWithATokens should burn approximately repayAmount of debt-asset aTokens");
        assertApproxEqAbs(reserveCashDeltaUnderlying, debtReductionUnderlying, 2, "underlying repay should add reserve cash equal to burned debt");
    }

    function _snapshot(address user, address variableDebtToken, address debtAToken) internal view returns (Snapshot memory s) {
        s.debt = IERC20(variableDebtToken).balanceOf(user);
        s.reserveCash = IERC20(DEBT_ASSET).balanceOf(debtAToken);
        s.aTokenSupply = IERC20(debtAToken).totalSupply();
    }

    function _repayUsingUnderlying(address user, uint256 repayAmount) internal {
        deal(DEBT_ASSET, user, repayAmount);

        vm.startPrank(user);
        IERC20(DEBT_ASSET).approve(address(POOL), type(uint256).max);
        POOL.repay(DEBT_ASSET, repayAmount, 2, user);
        vm.stopPrank();
    }

    function _repayUsingATokens(address user, uint256 repayAmount) internal {
        vm.startPrank(user);
        IAToken(POOL.getReserveData(DEBT_ASSET).aTokenAddress).approve(address(POOL), type(uint256).max);
        POOL.repayWithATokens(DEBT_ASSET, repayAmount, 2);
        vm.stopPrank();
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _openMatchingPosition(address user) internal returns (uint256 borrowAmount) {
        DataTypes.ReserveData memory collateralReserve = POOL.getReserveData(COLLATERAL_ASSET);
        uint256 collateralDecimals = collateralReserve.configuration.getDecimals();
        uint256 debtDecimals = POOL.getReserveData(DEBT_ASSET).configuration.getDecimals();
        uint256 ltv = collateralReserve.configuration.getLtv();

        uint256 maxBorrow =
            (((COLLATERAL_AMOUNT * BASE_PRICE) / (10 ** collateralDecimals)) * ltv / 10_000) * (10 ** debtDecimals) / BASE_PRICE;

        borrowAmount = (maxBorrow * 80) / 100;

        deal(COLLATERAL_ASSET, user, COLLATERAL_AMOUNT);

        vm.startPrank(user);
        IERC20(COLLATERAL_ASSET).approve(address(POOL), type(uint256).max);
        POOL.supply(COLLATERAL_ASSET, COLLATERAL_AMOUNT, user, 0);
        POOL.borrow(DEBT_ASSET, borrowAmount, 2, 0, user);
        vm.stopPrank();
    }
}