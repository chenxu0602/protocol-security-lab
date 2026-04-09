// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { BaseMarketReview } from "./BaseMarketReview.t.sol";
import { IMarket } from "perennial-v2/packages/core/contracts/interfaces/IMarket.sol";
import { Checkpoint } from "perennial-v2/packages/core/contracts/types/Checkpoint.sol";
import { Global } from "perennial-v2/packages/core/contracts/types/Global.sol";
import { Local } from "perennial-v2/packages/core/contracts/types/Local.sol";
import { MarketParameter } from "perennial-v2/packages/core/contracts/types/MarketParameter.sol";
import { OracleReceipt } from "perennial-v2/packages/core/contracts/types/OracleReceipt.sol";
import { OracleVersion } from "perennial-v2/packages/core/contracts/types/OracleVersion.sol";
import { Order } from "perennial-v2/packages/core/contracts/types/Order.sol";
import { Position, PositionLib } from "perennial-v2/packages/core/contracts/types/Position.sol";
import { RiskParameter } from "perennial-v2/packages/core/contracts/types/RiskParameter.sol";
import { Guarantee } from "perennial-v2/packages/core/contracts/types/Guarantee.sol";
import { Version } from "perennial-v2/packages/core/contracts/types/Version.sol";
import { VersionTester } from "perennial-v2/packages/core/contracts/test/VersionTester.sol";
import { VersionAccumulationResponse } from "perennial-v2/packages/core/contracts/libs/VersionLib.sol";
import { Fixed6, Fixed6Lib } from "@equilibria/root/number/types/Fixed6.sol";
import { UFixed6, UFixed6Lib } from "@equilibria/root/number/types/UFixed6.sol";

contract SocializationValueReconciliationTest is BaseMarketReview {
    function test_pnl_formula_usesSocializedLongBasis_notRawLongSize() public pure {
        Position memory position = Position({
            timestamp: 0,
            maker: UFixed6.wrap(1e6),
            long: UFixed6.wrap(3e6),
            short: UFixed6.wrap(1e6)
        });

        int256 pnlUsingSocializedLong =
            Fixed6.unwrap(Fixed6.wrap(2100e6).sub(Fixed6.wrap(2000e6)).mul(Fixed6Lib.from(position.longSocialized())));
        int256 pnlUsingRawLong =
            Fixed6.unwrap(Fixed6.wrap(2100e6).sub(Fixed6.wrap(2000e6)).mul(Fixed6Lib.from(position.long)));

        assertEq(UFixed6.unwrap(position.longSocialized()), 2e6, "long socialization should cap long size at maker + short");
        assertEq(pnlUsingSocializedLong, 200e6, "ordinary long pnl basis should use socialized long size");
        assertEq(pnlUsingRawLong, 300e6, "raw long size would overstate pnl in a stressed socialized state");
    }

    function test_funding_usesSocializedTakerNotionalBasis() public {
        _relaxRiskForNoCollateralTests();
        _disableInterest();
        _setFundingController(365 days * 1e6, -2_000_000, 2_000_000);
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 0);

        _openAndSettleMakerLiquidity(lp, 1e6);
        _openAndSettleTaker(taker, 1e6);

        (, , Checkpoint memory checkpoint, Fixed6 collateralDelta) =
            _realizeThroughNoop(taker, 2000e6, 365 days, 2000e6);

        int256 expectedFunding = -1_000e6;

        assertEq(
            Fixed6.unwrap(collateralDelta),
            expectedFunding,
            "long funding should be computed from socialized taker notional of 1 * 2000 over one year"
        );
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), 0, "trade fee should be zero");
        assertEq(UFixed6.unwrap(checkpoint.settlementFee), 0, "settlement fee should be zero");
    }

    function test_funding_dailyRealizationDiffersSlightlyFromSingleYearStep() public {
        // Characterization only: discrete daily settlement should stay close to the one-shot annual result,
        // but fixed-point rounding and stepwise controller updates can produce a small path-dependent gap.
        _relaxRiskForNoCollateralTests();
        _disableInterest();
        _setFundingController(365 days * 1e6, -2_000_000, 2_000_000);
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 0);

        _openAndSettleMakerLiquidity(lp, 1e6);
        _openAndSettleTaker(taker, 1e6);
        _depositAndSettle(taker, 2_000e6);

        uint256 snapshotId = vm.snapshotState();
        (, , , Fixed6 oneYearDelta) = _realizeThroughNoop(taker, 2000e6, 365 days, 2000e6);

        vm.revertToState(snapshotId);
        Fixed6 dailyDelta = _realizeThroughDailyNoops(taker, 2000e6, 365, 2000e6);

        assertEq(Fixed6.unwrap(oneYearDelta), -1_000e6, "single-step baseline should match the closed-form funding test");
        assertGt(Fixed6.unwrap(dailyDelta), Fixed6.unwrap(oneYearDelta), "daily funding realization should be slightly less negative");
        assertApproxEqAbs(
            uint256(_abs(Fixed6.unwrap(dailyDelta) - Fixed6.unwrap(oneYearDelta))),
            0,
            5e5,
            "daily stepping should stay within a small rounding / discretization band"
        );
    }

    function test_interest_usesUtilizedNotional_notRawGrossOpenInterest() public {
        _relaxRiskForNoCollateralTests();
        _disableFunding();
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 0);

        _openAndSettleMakerLiquidity(lp, 1e6);

        vm.prank(taker);
        market.update(taker, Fixed6.wrap(1e6), address(0));

        vm.prank(taker2);
        market.update(taker2, Fixed6.wrap(-1e6), address(0));

        _advanceOracle(2000e6);
        market.settle(taker);
        market.settle(taker2);

        (uint256 fromTimestamp, uint256 checkpointTimestamp, Checkpoint memory checkpoint, Fixed6 collateralDelta) =
            _realizeThroughNoop(lp, 2000e6, 365 days, 2000e6);

        uint256 dt = checkpointTimestamp - fromTimestamp;
        uint256 expectedInterest = 2_000e6 * 57_500 * dt / 365 days / 1e6;

        assertEq(
            uint256(Fixed6.unwrap(collateralDelta)),
            expectedInterest,
            "maker interest should use utilized notional min(long + short, maker) * price = 1 * 2000"
        );
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), 0, "trade fee should be zero");
        assertEq(UFixed6.unwrap(checkpoint.settlementFee), 0, "settlement fee should be zero");
    }

    function test_adiabaticExposure_routesToMakerWhenMakerExists_andToGlobalExposureWhenAbsent() public {
        // Source of truth:
        // 1. isolate VersionLib through VersionTester with closed=true so only exposure-related components run
        // 2. compare maker-present and maker-absent fromPosition shapes under the same skew and price move
        (Fixed6 makerValueWithoutAdiabatic, Fixed6 marketExposureWithoutAdiabatic) =
            _accumulateAdiabaticExposureOnly(_position(1e6, 1e6, 0), 0);
        (Fixed6 makerValueWithAdiabatic, Fixed6 marketExposureWithAdiabatic) =
            _accumulateAdiabaticExposureOnly(_position(1e6, 1e6, 0), 100_000);

        assertEq(Fixed6.unwrap(marketExposureWithoutAdiabatic), 0, "maker-present baseline should not route anything into market exposure");
        assertEq(Fixed6.unwrap(marketExposureWithAdiabatic), 0, "maker-present adiabatic exposure should stay out of Global.exposure");
        assertEq(
            Fixed6.unwrap(makerValueWithAdiabatic.sub(makerValueWithoutAdiabatic)),
            -5e6,
            "with makers present, the adiabatic exposure increment should be absorbed by maker value"
        );

        (, Fixed6 marketExposureWithoutMakerBaseline) = _accumulateAdiabaticExposureOnly(_position(0, 1e6, 0), 0);
        (, Fixed6 marketExposureWithoutMaker) = _accumulateAdiabaticExposureOnly(_position(0, 1e6, 0), 100_000);

        assertEq(Fixed6.unwrap(marketExposureWithoutMakerBaseline), 0, "maker-absent baseline should not route market exposure when adiabatic fee is zero");
        assertEq(Fixed6.unwrap(marketExposureWithoutMaker), -5e6, "without makers present, adiabatic exposure should route into market exposure");
    }

    function _realizeThroughNoop(
        address account,
        int256 syncPrice,
        uint256 horizon,
        int256 settlementPrice
    ) internal returns (uint256 fromTimestamp, uint256 checkpointTimestamp, Checkpoint memory checkpoint, Fixed6 collateralDelta) {
        uint256 syncTimestamp = oracle.current();
        _setOracle(syncTimestamp, syncPrice, true, syncTimestamp + horizon);

        market.settle(account);
        fromTimestamp = market.positions(account).timestamp;
        Fixed6 collateralBefore = market.locals(account).collateral;

        vm.prank(account);
        market.update(account, Fixed6Lib.ZERO, address(0));

        uint256 checkpointOrderId = market.locals(account).currentId;
        checkpointTimestamp = market.pendingOrders(account, checkpointOrderId).timestamp;

        _setOracle(checkpointTimestamp, settlementPrice, true, checkpointTimestamp + 1);
        market.settle(account);

        checkpoint = market.checkpoints(account, checkpointTimestamp);
        collateralDelta = market.locals(account).collateral.sub(collateralBefore);
    }

    function _realizeThroughDailyNoops(
        address account,
        int256 syncPrice,
        uint256 daysToAdvance,
        int256 settlementPrice
    ) internal returns (Fixed6 totalCollateralDelta) {
        for (uint256 i; i < daysToAdvance; ++i) {
            (, , , Fixed6 stepDelta) = _realizeThroughNoop(account, syncPrice, 1 days, settlementPrice);
            totalCollateralDelta = totalCollateralDelta.add(stepDelta);
        }
    }

    function _abs(int256 value) internal pure returns (int256) {
        return value >= 0 ? value : -value;
    }

    function _accumulateAdiabaticExposureOnly(
        Position memory fromPosition,
        uint256 adiabaticFee
    ) internal returns (Fixed6 makerValue, Fixed6 marketExposure) {
        VersionTester tester = new VersionTester();

        MarketParameter memory parameter = market.parameter();
        parameter.closed = true;
        parameter.makerFee = UFixed6Lib.ZERO;
        parameter.takerFee = UFixed6Lib.ZERO;
        parameter.fundingFee = UFixed6Lib.ZERO;
        parameter.interestFee = UFixed6Lib.ZERO;
        parameter.riskFee = UFixed6Lib.ZERO;

        RiskParameter memory risk = market.riskParameter();
        risk.takerFee.linearFee = UFixed6Lib.ZERO;
        risk.takerFee.proportionalFee = UFixed6Lib.ZERO;
        risk.takerFee.adiabaticFee = UFixed6.wrap(adiabaticFee);
        risk.takerFee.scale = UFixed6.wrap(1_000_000);

        IMarket.Context memory context = IMarket.Context({
            account: address(0),
            marketParameter: parameter,
            riskParameter: risk,
            latestOracleVersion: OracleVersion({ timestamp: 0, price: Fixed6.wrap(2000e6), valid: true }),
            currentTimestamp: 0,
            global: Global({
                currentId: 0,
                latestId: 0,
                protocolFee: UFixed6Lib.ZERO,
                oracleFee: UFixed6Lib.ZERO,
                riskFee: UFixed6Lib.ZERO,
                latestPrice: Fixed6.wrap(2000e6),
                exposure: Fixed6Lib.ZERO,
                pAccumulator: market.global().pAccumulator
            }),
            local: Local({ currentId: 0, latestId: 0, collateral: Fixed6Lib.ZERO, claimable: UFixed6Lib.ZERO }),
            latestPositionGlobal: fromPosition,
            latestPositionLocal: _position(0, 0, 0),
            pendingGlobal: _emptyOrder(),
            pendingLocal: _emptyOrder()
        });

        IMarket.SettlementContext memory settlementContext = IMarket.SettlementContext({
            latestVersion: Version({
                valid: true,
                price: Fixed6.wrap(2000e6),
                makerValue: market.versions(0).makerValue,
                longValue: market.versions(0).longValue,
                shortValue: market.versions(0).shortValue,
                makerFee: market.versions(0).makerFee,
                takerFee: market.versions(0).takerFee,
                makerOffset: market.versions(0).makerOffset,
                takerPosOffset: market.versions(0).takerPosOffset,
                takerNegOffset: market.versions(0).takerNegOffset,
                settlementFee: market.versions(0).settlementFee,
                liquidationFee: market.versions(0).liquidationFee
            }),
            latestCheckpoint: market.checkpoints(address(0), 0),
            orderOracleVersion: OracleVersion({ timestamp: 0, price: Fixed6.wrap(2000e6), valid: true })
        });

        (, VersionAccumulationResponse memory response) = tester.accumulate(
            context,
            settlementContext,
            1,
            _emptyOrder(),
            _emptyGuarantee(),
            OracleVersion({ timestamp: 1, price: Fixed6.wrap(2100e6), valid: true }),
            OracleReceipt({ settlementFee: UFixed6Lib.ZERO, oracleFee: UFixed6Lib.ZERO })
        );

        makerValue = tester.read().makerValue._value;
        marketExposure = response.marketExposure;
    }

    function _position(uint256 makerAmount, uint256 longAmount, uint256 shortAmount) internal pure returns (Position memory) {
        return Position({
            timestamp: 0,
            maker: UFixed6.wrap(makerAmount),
            long: UFixed6.wrap(longAmount),
            short: UFixed6.wrap(shortAmount)
        });
    }

    function _emptyOrder() internal pure returns (Order memory) {
        return Order(0, 0, Fixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, 0, 0, UFixed6Lib.ZERO, UFixed6Lib.ZERO);
    }

    function _emptyGuarantee() internal pure returns (Guarantee memory) {
        return Guarantee(0, Fixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO, UFixed6Lib.ZERO);
    }
}
