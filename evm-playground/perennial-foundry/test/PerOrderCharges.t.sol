// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { BaseMarketReview } from "./BaseMarketReview.t.sol";
import { Checkpoint } from "perennial-v2/packages/core/contracts/types/Checkpoint.sol";
import { Version } from "perennial-v2/packages/core/contracts/types/Version.sol";
import { Accumulator6 } from "@equilibria/root/accumulator/types/Accumulator6.sol";
import { Fixed6, Fixed6Lib } from "@equilibria/root/number/types/Fixed6.sol";
import { UFixed6, UFixed6Lib } from "@equilibria/root/number/types/UFixed6.sol";

contract PerOrderChargesTest is BaseMarketReview {
    function test_settlementFee_chargesPerNonEmptyOrder_notNoopUpdate() public {
        _relaxRiskForNoCollateralTests();
        _setOracleReceipt(5e6, 0);
        _setMarketFees(0, 0);
        _openAndSettleMakerLiquidity(lp, 10e6);

        vm.prank(taker);
        market.update(taker, Fixed6.wrap(1e6), address(0));
        uint256 takerOrderId = market.locals(taker).currentId;
        uint256 takerOrderTimestamp = market.pendingOrders(taker, takerOrderId).timestamp;

        vm.prank(taker2);
        market.update(taker2, Fixed6Lib.ZERO, address(0));
        uint256 noopOrderId = market.locals(taker2).currentId;
        uint256 noopOrderTimestamp = market.pendingOrders(taker2, noopOrderId).timestamp;

        _advanceOracle(2000e6);
        market.settle(taker);
        market.settle(taker2);

        Checkpoint memory takerCheckpoint = market.checkpoints(taker, takerOrderTimestamp);
        Checkpoint memory noopCheckpoint = market.checkpoints(taker2, noopOrderTimestamp);

        assertEq(UFixed6.unwrap(takerCheckpoint.settlementFee), 5e6, "non-empty order should pay one settlement fee");
        assertEq(UFixed6.unwrap(noopCheckpoint.settlementFee), 0, "noop order should not pay settlement fee");
    }

    function test_protectedOrder_realizesLiquidationFeeOnce_andCreditsLiquidator() public {
        _setOracleReceipt(1e6, 0);
        _setMarketFees(0, 0);

        _setAbsolutePosition(lp, lp, 1e6, 0, 0, 250e6, false);
        _setAbsolutePosition(taker, taker, 0, 1e6, 0, 250e6, false);

        _advanceOracle(2000e6);
        market.settle(taker);
        market.settle(lp);

        _advanceOracle(1800e6);
        market.settle(lp);

        _setAbsolutePosition(solver, taker, 0, 0, 0, 0, true);

        uint256 liquidationOrderId = market.locals(taker).currentId;
        uint256 liquidationOrderTimestamp = market.pendingOrders(taker, liquidationOrderId).timestamp;

        _advanceOracle(1800e6);
        market.settle(taker);

        Checkpoint memory liquidationCheckpoint = market.checkpoints(taker, liquidationOrderTimestamp);

        assertEq(
            UFixed6.unwrap(liquidationCheckpoint.settlementFee),
            11e6,
            "protected order should realize one settlement fee plus one liquidation fee"
        );
        assertEq(UFixed6.unwrap(market.locals(solver).claimable), 10e6, "liquidator should receive exactly one liquidation fee credit");

        _advanceOracle(1800e6);
        market.settle(taker);

        assertEq(UFixed6.unwrap(market.locals(solver).claimable), 10e6, "liquidation fee should not be credited again on later settles");
    }

    function test_settlementFee_splitsAcrossAggregatedOrderCount() public {
        _relaxRiskForNoCollateralTests();
        _setOracleReceipt(1e6, 0);
        _setMarketFees(0, 0);
        _openAndSettleMakerLiquidity(lp, 10e6);

        vm.prank(taker);
        market.update(taker, Fixed6.wrap(1e6), address(0));
        uint256 takerOrderId = market.locals(taker).currentId;
        uint256 takerOrderTimestamp = market.pendingOrders(taker, takerOrderId).timestamp;

        vm.prank(taker2);
        market.update(taker2, Fixed6.wrap(1e6), address(0));
        uint256 taker2OrderId = market.locals(taker2).currentId;
        uint256 taker2OrderTimestamp = market.pendingOrders(taker2, taker2OrderId).timestamp;

        assertEq(takerOrderTimestamp, taker2OrderTimestamp, "both non-empty orders should aggregate into the same settlement interval");

        _advanceOracle(2000e6);
        market.settle(taker);
        market.settle(taker2);

        Checkpoint memory takerCheckpoint = market.checkpoints(taker, takerOrderTimestamp);
        Checkpoint memory taker2Checkpoint = market.checkpoints(taker2, taker2OrderTimestamp);
        Version memory version = market.versions(takerOrderTimestamp);
        UFixed6 aggregatedFee = version.settlementFee.accumulated(Accumulator6(Fixed6Lib.ZERO), UFixed6.wrap(2e6)).abs();

        assertEq(UFixed6.unwrap(takerCheckpoint.settlementFee), 5e5, "each order should realize half of the 1-unit settlement fee");
        assertEq(UFixed6.unwrap(taker2Checkpoint.settlementFee), 5e5, "each order should realize half of the 1-unit settlement fee");
        assertEq(UFixed6.unwrap(aggregatedFee), 1e6, "version settlement-fee accumulator should preserve the full fee across aggregated order count");
    }

    function test_protectedOrders_keepFullLiquidationFeeWhileSplittingSettlementFee() public {
        _setOracleReceipt(1e6, 0);
        _setMarketFees(0, 0);

        _setAbsolutePosition(lp, lp, 2e6, 0, 0, 500e6, false);
        _setAbsolutePosition(taker, taker, 0, 1e6, 0, 250e6, false);
        _setAbsolutePosition(taker2, taker2, 0, 1e6, 0, 250e6, false);

        _advanceOracle(2000e6);
        market.settle(taker);
        market.settle(taker2);
        market.settle(lp);

        _advanceOracle(1800e6);
        market.settle(lp);

        _setAbsolutePosition(solver, taker, 0, 0, 0, 0, true);
        uint256 takerOrderId = market.locals(taker).currentId;
        uint256 takerOrderTimestamp = market.pendingOrders(taker, takerOrderId).timestamp;

        _setAbsolutePosition(solver, taker2, 0, 0, 0, 0, true);
        uint256 taker2OrderId = market.locals(taker2).currentId;
        uint256 taker2OrderTimestamp = market.pendingOrders(taker2, taker2OrderId).timestamp;

        assertEq(takerOrderTimestamp, taker2OrderTimestamp, "both protected orders should aggregate into the same settlement interval");

        _advanceOracle(1800e6);
        market.settle(taker);
        market.settle(taker2);

        Checkpoint memory takerCheckpoint = market.checkpoints(taker, takerOrderTimestamp);
        Checkpoint memory taker2Checkpoint = market.checkpoints(taker2, taker2OrderTimestamp);

        assertEq(UFixed6.unwrap(takerCheckpoint.settlementFee), 10_500_000, "protected order should keep full liquidation fee plus half of the shared settlement fee");
        assertEq(UFixed6.unwrap(taker2Checkpoint.settlementFee), 10_500_000, "second protected order should keep full liquidation fee plus half of the shared settlement fee");
        assertEq(UFixed6.unwrap(market.locals(solver).claimable), 20e6, "liquidator should receive one full liquidation fee per protected order");
    }

    function test_protectedOrderCheckpoint_reconcilesToLocalCollateralDelta() public {
        _setOracleReceipt(1e6, 0);
        _setMarketFees(0, 0);

        _setAbsolutePosition(lp, lp, 1e6, 0, 0, 250e6, false);
        _setAbsolutePosition(taker, taker, 0, 1e6, 0, 250e6, false);

        _advanceOracle(2000e6);
        market.settle(taker);
        market.settle(lp);

        _advanceOracle(1800e6);
        market.settle(lp);

        _setAbsolutePosition(solver, taker, 0, 0, 0, 0, true);

        uint256 liquidationOrderId = market.locals(taker).currentId;
        uint256 liquidationOrderTimestamp = market.pendingOrders(taker, liquidationOrderId).timestamp;

        _advanceOracle(1800e6);
        market.settle(taker);

        Checkpoint memory checkpoint = market.checkpoints(taker, liquidationOrderTimestamp);
        Fixed6 collateralAfter = market.locals(taker).collateral;
        Fixed6 expectedCollateral = checkpoint.transfer
            .add(checkpoint.collateral)
            .sub(checkpoint.tradeFee)
            .sub(Fixed6Lib.from(checkpoint.settlementFee));

        assertEq(Fixed6.unwrap(checkpoint.transfer), 0, "protected close path should not include an explicit collateral transfer");
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), 0, "protected close path should not realize ordinary maker or taker trade fee");
        assertEq(Fixed6.unwrap(collateralAfter), Fixed6.unwrap(expectedCollateral), "protected checkpoint fields should reconcile to the settled local collateral");
    }
}
