// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { Market } from "perennial-v2/packages/core/contracts/Market.sol";
import { MockToken } from "perennial-v2/packages/core/contracts/test/MockToken.sol";
import { OracleVersion } from "perennial-v2/packages/core/contracts/types/OracleVersion.sol";
import { OracleReceipt } from "perennial-v2/packages/core/contracts/types/OracleReceipt.sol";
import { MarketParameter } from "perennial-v2/packages/core/contracts/types/MarketParameter.sol";
import { RiskParameter } from "perennial-v2/packages/core/contracts/types/RiskParameter.sol";

import { Fixed6, Fixed6Lib } from "@equilibria/root/number/types/Fixed6.sol";
import { UFixed6, UFixed6Lib } from "@equilibria/root/number/types/UFixed6.sol";
import { Token18 } from "@equilibria/root/token/types/Token18.sol";
import { PController6 } from "@equilibria/root/pid/types/PController6.sol";
import { UJumpRateUtilizationCurve6 } from "@equilibria/root/utilization/types/UJumpRateUtilizationCurve6.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockMarket } from "src/mocks/MockMarket.sol";
import { MockOracleProvider } from "src/mocks/MockOracleProvider.sol";
import { MockVerifier } from "src/mocks/MockVerifier.sol";
import { MockMarketFactory } from "src/mocks/MockMarketFactory.sol";

abstract contract BaseMarketReview is Test {
    address internal owner = address(this);
    address internal lp = makeAddr("lp");
    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");
    address internal taker2 = makeAddr("taker2");
    address internal solver = makeAddr("solver");
    address internal referrer = makeAddr("referrer");

    MockToken internal token;
    MockOracleProvider internal oracle;
    MockMarket internal deployer;
    MockVerifier internal verifier;
    MockMarketFactory internal factory;
    Market internal market;

    function setUp() public virtual {
        token = new MockToken();
        oracle = new MockOracleProvider();
        deployer = new MockMarket();

        _setOracle(block.timestamp, 2000e6, true, block.timestamp + 1);
        (market, factory, verifier) = deployer.create(address(token), oracle);
    }

    function _setOracle(uint256 timestamp, int256 price, bool valid, uint256 nextTimestamp) internal {
        oracle.setStatus(
            OracleVersion({
                timestamp: timestamp,
                price: Fixed6.wrap(price),
                valid: valid
            }),
            nextTimestamp
        );
    }

    function _marketToken() internal view returns (address) {
        return Token18.unwrap(market.token());
    }

    function _fixed(int256 value) internal pure returns (Fixed6) {
        return Fixed6.wrap(value);
    }

    function _ufixed(uint256 value) internal pure returns (UFixed6) {
        return UFixed6.wrap(value);
    }

    function _advanceOracle(int256 nextPrice) internal {
        uint256 nextTimestamp = oracle.current();
        _setOracle(nextTimestamp, nextPrice, true, nextTimestamp + 1);
    }

    function _advanceOracleWithValidity(int256 nextPrice, bool valid) internal {
        uint256 nextTimestamp = oracle.current();
        _setOracle(nextTimestamp, nextPrice, valid, nextTimestamp + 1);
    }

    function _setOracleReceipt(uint256 settlementFee, uint256 oracleFee) internal {
        oracle.setReceipt(OracleReceipt({ settlementFee: UFixed6.wrap(settlementFee), oracleFee: UFixed6.wrap(oracleFee) }));
    }

    function _setMarketFees(uint256 makerFee, uint256 takerFee) internal {
        MarketParameter memory parameter = market.parameter();
        parameter.makerFee = UFixed6.wrap(makerFee);
        parameter.takerFee = UFixed6.wrap(takerFee);
        deployer.updateMarketParameter(market, parameter);
    }

    function _relaxRiskForNoCollateralTests() internal {
        RiskParameter memory risk = market.riskParameter();
        risk.margin = UFixed6Lib.ZERO;
        risk.maintenance = UFixed6Lib.ZERO;
        risk.minMargin = UFixed6Lib.ZERO;
        risk.minMaintenance = UFixed6Lib.ZERO;
        deployer.updateRiskParameter(market, risk);
    }

    function _openAndSettleMakerLiquidity(address account, int256 makerAmount) internal {
        vm.prank(account);
        market.update(account, Fixed6.wrap(makerAmount), Fixed6Lib.ZERO, Fixed6Lib.ZERO, address(0));

        _advanceOracle(2000e6);
        market.settle(account);
    }

    function _openAndSettleTaker(address account, int256 takerAmount) internal {
        vm.prank(account);
        market.update(account, Fixed6.wrap(takerAmount), address(0));

        _advanceOracle(2000e6);
        market.settle(account);
    }

    function _enableSelfSigner(address account) internal {
        vm.prank(account);
        factory.updateSigner(account, true);
    }

    function _depositAndSettle(address account, int256 collateral) internal {
        _mockTransferFromSuccess();

        vm.prank(account);
        market.update(account, Fixed6Lib.ZERO, Fixed6Lib.from(collateral), address(0));

        _advanceOracle(2000e6);
        market.settle(account);
    }

    function _mockTransferFromSuccess() internal {
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(IERC20.transferFrom.selector),
            abi.encode(true)
        );
    }

    function _setAbsolutePosition(
        address caller,
        address account,
        uint256 newMaker,
        uint256 newLong,
        uint256 newShort,
        int256 collateral,
        bool protect
    ) internal {
        if (collateral > 0) _mockTransferFromSuccess();

        vm.prank(caller);
        market.update(
            account,
            UFixed6.wrap(newMaker),
            UFixed6.wrap(newLong),
            UFixed6.wrap(newShort),
            Fixed6.wrap(collateral),
            protect
        );
    }

    function _disableFunding() internal {
        RiskParameter memory risk = market.riskParameter();
        risk.pController = PController6({
            k: risk.pController.k,
            min: Fixed6Lib.ZERO,
            max: Fixed6Lib.ZERO
        });
        deployer.updateRiskParameter(market, risk);
    }

    function _disableInterest() internal {
        RiskParameter memory risk = market.riskParameter();
        risk.utilizationCurve = UJumpRateUtilizationCurve6({
            minRate: UFixed6Lib.ZERO,
            maxRate: UFixed6Lib.ZERO,
            targetRate: UFixed6Lib.ZERO,
            targetUtilization: risk.utilizationCurve.targetUtilization
        });
        deployer.updateRiskParameter(market, risk);
    }

    function _disableFundingAndInterest() internal {
        RiskParameter memory risk = market.riskParameter();
        risk.pController = PController6({
            k: risk.pController.k,
            min: Fixed6Lib.ZERO,
            max: Fixed6Lib.ZERO
        });
        risk.utilizationCurve = UJumpRateUtilizationCurve6({
            minRate: UFixed6Lib.ZERO,
            maxRate: UFixed6Lib.ZERO,
            targetRate: UFixed6Lib.ZERO,
            targetUtilization: risk.utilizationCurve.targetUtilization
        });
        deployer.updateRiskParameter(market, risk);
    }

    function _setFundingController(uint256 k, int256 minValue, int256 maxValue) internal {
        RiskParameter memory risk = market.riskParameter();
        risk.pController = PController6({
            k: UFixed6.wrap(k),
            min: Fixed6.wrap(minValue),
            max: Fixed6.wrap(maxValue)
        });
        deployer.updateRiskParameter(market, risk);
    }

    function _setRiskTakerImpactFees(
        uint256 linearFee,
        uint256 proportionalFee,
        uint256 adiabaticFee,
        uint256 scale
    ) internal {
        RiskParameter memory risk = market.riskParameter();
        risk.takerFee.linearFee = UFixed6.wrap(linearFee);
        risk.takerFee.proportionalFee = UFixed6.wrap(proportionalFee);
        risk.takerFee.adiabaticFee = UFixed6.wrap(adiabaticFee);
        risk.takerFee.scale = UFixed6.wrap(scale);
        deployer.updateRiskParameter(market, risk);
    }
}
