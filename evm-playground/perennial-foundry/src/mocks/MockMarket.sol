// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { Market } from "perennial-v2/packages/core/contracts/Market.sol";
import { IMarket } from "perennial-v2/packages/core/contracts/interfaces/IMarket.sol";
import { IOracleProvider } from "perennial-v2/packages/core/contracts/interfaces/IOracleProvider.sol";
import { MarketParameter } from "perennial-v2/packages/core/contracts/types/MarketParameter.sol";
import { RiskParameter } from "perennial-v2/packages/core/contracts/types/RiskParameter.sol";
import { ProtocolParameter } from "perennial-v2/packages/core/contracts/types/ProtocolParameter.sol";
import { UFixed6 } from "@equilibria/root/number/types/UFixed6.sol";
import { Fixed6 } from "@equilibria/root/number/types/Fixed6.sol";
import { Token18 } from "@equilibria/root/token/types/Token18.sol";
import { UJumpRateUtilizationCurve6 } from "@equilibria/root/utilization/types/UJumpRateUtilizationCurve6.sol";
import { PController6 } from "@equilibria/root/pid/types/PController6.sol";
import { LinearAdiabatic6 } from "@equilibria/root/adiabatic/types/LinearAdiabatic6.sol";
import { NoopAdiabatic6 } from "@equilibria/root/adiabatic/types/NoopAdiabatic6.sol";

import { MockVerifier } from "src/mocks/MockVerifier.sol";
import { MockMarketFactory } from "src/mocks/MockMarketFactory.sol";

contract MockMarket {
    function create(address token, IOracleProvider oracle)
        external
        returns (Market market, MockMarketFactory factory, MockVerifier verifier)
    {
        verifier = new MockVerifier();
        factory = new MockMarketFactory(verifier);
        market = new Market(verifier);

        factory.updateParameter(_defaultProtocolParameter());
        factory.initializeMarket(
            market,
            IMarket.MarketDefinition({
                token: Token18.wrap(token),
                oracle: oracle
            })
        );

        market.updateRiskParameter(_defaultRiskParameter());
        market.updateParameter(_defaultMarketParameter());
    }

    function defaultProtocolParameter() external pure returns (ProtocolParameter memory) {
        return _defaultProtocolParameter();
    }

    function defaultRiskParameter() external pure returns (RiskParameter memory) {
        return _defaultRiskParameter();
    }

    function defaultMarketParameter() external pure returns (MarketParameter memory) {
        return _defaultMarketParameter();
    }

    function updateRiskParameter(Market market, RiskParameter memory newRiskParameter) external {
        market.updateRiskParameter(newRiskParameter);
    }

    function updateMarketParameter(Market market, MarketParameter memory newMarketParameter) external {
        market.updateParameter(newMarketParameter);
    }

    function _defaultProtocolParameter() internal pure returns (ProtocolParameter memory) {
        return ProtocolParameter({
            maxFee: UFixed6.wrap(1_000_000),
            maxLiquidationFee: UFixed6.wrap(25_000_000),
            maxCut: UFixed6.wrap(1_000_000),
            maxRate: UFixed6.wrap(50_000_000),
            minMaintenance: UFixed6.wrap(0),
            minEfficiency: UFixed6.wrap(0),
            referralFee: UFixed6.wrap(400_000),
            minScale: UFixed6.wrap(0),
            maxStaleAfter: 86_400
        });
    }

    function _defaultRiskParameter() internal pure returns (RiskParameter memory) {
        return RiskParameter({
            margin: UFixed6.wrap(100_000),
            maintenance: UFixed6.wrap(100_000),
            takerFee: LinearAdiabatic6({
                linearFee: UFixed6.wrap(0),
                proportionalFee: UFixed6.wrap(0),
                adiabaticFee: UFixed6.wrap(0),
                scale: UFixed6.wrap(1_000_000)
            }),
            makerFee: NoopAdiabatic6({
                linearFee: UFixed6.wrap(0),
                proportionalFee: UFixed6.wrap(0),
                scale: UFixed6.wrap(1_000_000)
            }),
            makerLimit: UFixed6.wrap(100_000_000),
            efficiencyLimit: UFixed6.wrap(200_000),
            liquidationFee: UFixed6.wrap(10_000_000),
            utilizationCurve: UJumpRateUtilizationCurve6({
                minRate: UFixed6.wrap(20_000),
                maxRate: UFixed6.wrap(800_000),
                targetRate: UFixed6.wrap(80_000),
                targetUtilization: UFixed6.wrap(800_000)
            }),
            pController: PController6({
                k: UFixed6.wrap(40_000_000_000),
                min: Fixed6.wrap(-1_200_000),
                max: Fixed6.wrap(1_200_000)
            }),
            minMargin: UFixed6.wrap(100_000_000),
            minMaintenance: UFixed6.wrap(100_000_000),
            staleAfter: 7_200,
            makerReceiveOnly: false
        });
    }

    function _defaultMarketParameter() internal pure returns (MarketParameter memory) {
        return MarketParameter({
            fundingFee: UFixed6.wrap(0),
            interestFee: UFixed6.wrap(0),
            makerFee: UFixed6.wrap(0),
            takerFee: UFixed6.wrap(0),
            riskFee: UFixed6.wrap(0),
            maxPendingGlobal: 8,
            maxPendingLocal: 8,
            maxPriceDeviation: UFixed6.wrap(100_000),
            closed: false,
            settle: false
        });
    }
}
