// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { BaseMarketReview } from "./BaseMarketReview.t.sol";
import { Checkpoint } from "perennial-v2/packages/core/contracts/types/Checkpoint.sol";
import { Intent } from "perennial-v2/packages/core/contracts/types/Intent.sol";
import { Order } from "perennial-v2/packages/core/contracts/types/Order.sol";
import { Version } from "perennial-v2/packages/core/contracts/types/Version.sol";
import { MarketParameter } from "perennial-v2/packages/core/contracts/types/MarketParameter.sol";
import { ProtocolParameter } from "perennial-v2/packages/core/contracts/types/ProtocolParameter.sol";
import { Common } from "@equilibria/root/verifier/types/Common.sol";
import { Accumulator6 } from "@equilibria/root/accumulator/types/Accumulator6.sol";
import { Fixed6, Fixed6Lib } from "@equilibria/root/number/types/Fixed6.sol";
import { UFixed6, UFixed6Lib } from "@equilibria/root/number/types/UFixed6.sol";

contract FullDecompositionTest is BaseMarketReview {
    function test_plainTakerCheckpoint_reconcilesToLocalCollateralDelta() public {
        _relaxRiskForNoCollateralTests();
        _disableFundingAndInterest();
        _setOracleReceipt(5e6, 0);
        _setMarketFees(0, 10_000);

        _openAndSettleMakerLiquidity(lp, 10e6);

        Fixed6 collateralBefore = market.locals(taker).collateral;

        _mockTransferFromSuccess();
        vm.prank(taker);
        market.update(taker, Fixed6.wrap(1e6), Fixed6.wrap(100e6), address(0));

        uint256 orderId = market.locals(taker).currentId;
        uint256 orderTimestamp = market.pendingOrders(taker, orderId).timestamp;

        _advanceOracle(2000e6);
        market.settle(taker);

        Checkpoint memory checkpoint = market.checkpoints(taker, orderTimestamp);
        Fixed6 collateralAfter = market.locals(taker).collateral;
        Fixed6 collateralDelta = collateralAfter.sub(collateralBefore);
        Fixed6 expectedDelta = checkpoint.transfer
            .add(checkpoint.collateral)
            .sub(checkpoint.tradeFee)
            .sub(Fixed6Lib.from(checkpoint.settlementFee));

        assertEq(Fixed6.unwrap(checkpoint.transfer), 100e6, "the order should carry a 100-unit collateral transfer");
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), 20e6, "1 unit at price 2000 with 1% taker fee should pay 20");
        assertEq(UFixed6.unwrap(checkpoint.settlementFee), 5e6, "non-empty order should pay one settlement fee");
        assertEq(Fixed6.unwrap(collateralDelta), 75e6, "net local collateral should equal deposit minus trade fee and settlement fee");
        assertEq(Fixed6.unwrap(collateralDelta), Fixed6.unwrap(expectedDelta), "checkpoint fields should reconcile to the local collateral delta");
    }

    function test_guaranteedIntentCheckpoint_decomposesIntoPriceOverrideTradeFeeAndClaimables() public {
        _relaxRiskForNoCollateralTests();
        _disableFundingAndInterest();
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 10_000);

        _openAndSettleMakerLiquidity(lp, 10e6);
        _enableSelfSigner(taker);
        factory.updateReferralFee(referrer, UFixed6.wrap(400_000));
        _mockTransferFromSuccess();
        vm.prank(maker);
        market.update(maker, Fixed6Lib.ZERO, Fixed6.wrap(200e6), address(0));
        _advanceOracle(2000e6);
        market.settle(maker);

        Intent memory intent = _intent(taker, solver, 1e6, 1900e6, referrer, 500_000);

        Fixed6 collateralBefore = market.locals(taker).collateral;

        vm.prank(maker);
        market.update(maker, intent, "");

        uint256 orderId = market.locals(taker).currentId;
        uint256 orderTimestamp = market.pendingOrders(taker, orderId).timestamp;

        _advanceOracle(2000e6);
        market.settle(taker);

        Checkpoint memory checkpoint = market.checkpoints(taker, orderTimestamp);
        Fixed6 collateralAfter = market.locals(taker).collateral;
        Fixed6 collateralDelta = collateralAfter.sub(collateralBefore);
        Fixed6 expectedDelta = checkpoint.collateral
            .sub(checkpoint.tradeFee)
            .sub(Fixed6Lib.from(checkpoint.settlementFee));

        assertEq(Fixed6.unwrap(checkpoint.collateral), 100e6, "checkpoint collateral should store the guaranteed price adjustment only");
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), 20e6, "trader leg should still pay the ordinary 1% taker fee");
        assertEq(UFixed6.unwrap(checkpoint.settlementFee), 0, "guaranteed order count should not pay ordinary settlement fee");
        assertEq(Fixed6.unwrap(collateralDelta), 80e6, "realized local collateral should be price override minus ordinary trade fee");
        assertEq(Fixed6.unwrap(collateralDelta), Fixed6.unwrap(expectedDelta), "checkpoint fields should reconcile to the local collateral delta");

        assertEq(UFixed6.unwrap(market.locals(referrer).claimable), 4e6, "originator should receive the non-solver subtractive fee share");
        assertEq(UFixed6.unwrap(market.locals(solver).claimable), 4e6, "solver should receive its carved-out solver fee share");
    }

    function test_plainTakerFeeAccumulatorWrite_reconcilesToCheckpointTradeFee() public {
        _relaxRiskForNoCollateralTests();
        _disableFundingAndInterest();
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 10_000);

        _openAndSettleMakerLiquidity(lp, 10e6);
        _depositAndSettle(taker, 100e6);

        vm.prank(taker);
        market.update(taker, Fixed6.wrap(1e6), address(0));

        uint256 orderId = market.locals(taker).currentId;
        Order memory order = market.pendingOrders(taker, orderId);
        uint256 orderTimestamp = order.timestamp;

        _advanceOracle(2000e6);
        market.settle(taker);

        Version memory version = market.versions(orderTimestamp);
        Checkpoint memory checkpoint = market.checkpoints(taker, orderTimestamp);
        Fixed6 realizedByAccumulator = Fixed6Lib.ZERO.sub(
            version.takerFee.accumulated(Accumulator6(Fixed6Lib.ZERO), order.takerTotal())
        );

        assertEq(Fixed6.unwrap(realizedByAccumulator), 20e6, "version taker-fee write should encode the full 1% taker fee");
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), Fixed6.unwrap(realizedByAccumulator), "checkpoint trade fee should match the version taker-fee write exactly");
    }

    function test_plainMakerFeeAccumulatorWrite_reconcilesToCheckpointTradeFee() public {
        _relaxRiskForNoCollateralTests();
        _disableFundingAndInterest();
        _setOracleReceipt(0, 0);
        _setMarketFees(10_000, 0);

        vm.prank(maker);
        market.update(maker, Fixed6.wrap(2e6), Fixed6Lib.ZERO, Fixed6Lib.ZERO, address(0));

        uint256 orderId = market.locals(maker).currentId;
        Order memory order = market.pendingOrders(maker, orderId);
        uint256 orderTimestamp = order.timestamp;

        _advanceOracle(2000e6);
        market.settle(maker);

        Version memory version = market.versions(orderTimestamp);
        Checkpoint memory checkpoint = market.checkpoints(maker, orderTimestamp);
        Fixed6 realizedByAccumulator = Fixed6Lib.ZERO.sub(
            version.makerFee.accumulated(Accumulator6(Fixed6Lib.ZERO), order.makerTotal())
        );

        assertEq(Fixed6.unwrap(realizedByAccumulator), 40e6, "version maker-fee write should encode the full 1% maker fee");
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), Fixed6.unwrap(realizedByAccumulator), "checkpoint trade fee should match the version maker-fee write exactly");
    }

    function test_offsetOnlyCheckpoint_reconcilesToLocalCollateralDelta() public {
        _relaxRiskForNoCollateralTests();
        _disableFundingAndInterest();
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 0);
        _setRiskTakerImpactFees(10_000, 0, 0, 1_000_000);

        _openAndSettleMakerLiquidity(lp, 10e6);
        _mockTransferFromSuccess();
        vm.prank(taker);
        market.update(taker, Fixed6Lib.ZERO, Fixed6.wrap(100e6), address(0));
        _advanceOracle(2000e6);
        market.settle(taker);

        Fixed6 collateralBefore = market.locals(taker).collateral;

        vm.prank(taker);
        market.update(taker, Fixed6.wrap(1e6), address(0));

        uint256 orderId = market.locals(taker).currentId;
        Order memory order = market.pendingOrders(taker, orderId);
        uint256 orderTimestamp = order.timestamp;

        _advanceOracle(2000e6);
        market.settle(taker);

        Version memory version = market.versions(orderTimestamp);
        Checkpoint memory checkpoint = market.checkpoints(taker, orderTimestamp);
        Fixed6 collateralAfter = market.locals(taker).collateral;
        Fixed6 collateralDelta = collateralAfter.sub(collateralBefore);
        Fixed6 realizedOffset = Fixed6Lib.ZERO.sub(
            version.takerPosOffset.accumulated(Accumulator6(Fixed6Lib.ZERO), order.takerPos())
        );
        Fixed6 expectedLocalCollateral = checkpoint.transfer
            .add(checkpoint.collateral)
            .sub(checkpoint.tradeFee)
            .sub(Fixed6Lib.from(checkpoint.settlementFee));

        assertEq(Fixed6.unwrap(checkpoint.tradeFee), Fixed6.unwrap(realizedOffset), "checkpoint trade fee should equal pure offset when base maker/taker fees are disabled");
        assertEq(Fixed6.unwrap(checkpoint.collateral), Fixed6.unwrap(collateralBefore), "checkpoint collateral should preserve the prior baseline when only offset is realized");
        assertEq(Fixed6.unwrap(collateralAfter), Fixed6.unwrap(expectedLocalCollateral), "checkpoint fields should reconcile to the settled local collateral");
        assertEq(Fixed6.unwrap(collateralDelta), -Fixed6.unwrap(realizedOffset), "local collateral delta should equal the isolated offset charge with opposite sign");
    }

    function test_guaranteedIntentCheckpoint_explicitlySplitsGrossSubtractiveSolverAndNetLocalEffect() public {
        // Source of truth:
        // 1. checkpoint.tradeFee is the gross trader-facing fee on the trader leg
        // 2. referrer / solver claimables are the externally visible subtractive-fee outputs
        // 3. global.protocolFee delta is the retained remainder after subtractive routing
        _relaxRiskForNoCollateralTests();
        _disableFundingAndInterest();
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 10_000);

        ProtocolParameter memory protocolParameter = factory.parameter();
        protocolParameter.referralFee = UFixed6Lib.ZERO;
        factory.updateParameter(protocolParameter);

        MarketParameter memory parameter = market.parameter();
        parameter.riskFee = UFixed6Lib.ZERO;
        deployer.updateMarketParameter(market, parameter);

        _openAndSettleMakerLiquidity(lp, 10e6);
        _enableSelfSigner(taker);
        factory.updateReferralFee(referrer, UFixed6.wrap(400_000));
        _mockTransferFromSuccess();
        vm.prank(maker);
        market.update(maker, Fixed6Lib.ZERO, Fixed6.wrap(200e6), address(0));
        _advanceOracle(2000e6);
        market.settle(maker);

        Fixed6 collateralBefore = market.locals(taker).collateral;
        UFixed6 protocolFeeBefore = market.global().protocolFee;
        UFixed6 referrerClaimableBefore = market.locals(referrer).claimable;
        UFixed6 solverClaimableBefore = market.locals(solver).claimable;

        vm.prank(maker);
        market.update(maker, _intent(taker, solver, 1e6, 1900e6, referrer, 500_000), "");

        uint256 orderId = market.locals(taker).currentId;
        uint256 orderTimestamp = market.pendingOrders(taker, orderId).timestamp;

        _advanceOracle(2000e6);
        market.settle(taker);

        Checkpoint memory checkpoint = market.checkpoints(taker, orderTimestamp);
        Fixed6 collateralDelta = market.locals(taker).collateral.sub(collateralBefore);
        UFixed6 protocolFeeDelta = market.global().protocolFee.sub(protocolFeeBefore);
        UFixed6 referrerClaimableDelta = market.locals(referrer).claimable.sub(referrerClaimableBefore);
        UFixed6 solverClaimableDelta = market.locals(solver).claimable.sub(solverClaimableBefore);

        uint256 grossTradeFee = 20e6;
        uint256 subtractiveFee = 8e6;
        uint256 solverFee = 4e6;
        uint256 retainedTradeFee = grossTradeFee - subtractiveFee;

        assertEq(Fixed6.unwrap(checkpoint.tradeFee), int256(grossTradeFee), "checkpoint trade fee should expose the gross trader-facing trade fee");
        assertEq(UFixed6.unwrap(referrerClaimableDelta), subtractiveFee - solverFee, "originator claimable delta should equal subtractive fee net of solver carve-out");
        assertEq(UFixed6.unwrap(solverClaimableDelta), solverFee, "solver claimable delta should equal the carved-out solver fee");
        assertEq(UFixed6.unwrap(protocolFeeDelta), retainedTradeFee, "global protocol fee delta should retain only the non-subtractive gross trade fee remainder");
        assertEq(Fixed6.unwrap(collateralDelta), 80e6, "trader local collateral delta should still equal price override minus gross trade fee");
    }

    function _intent(
        address trader,
        address solver_,
        int256 amount,
        int256 price,
        address originator,
        uint256 solverFee
    ) internal view returns (Intent memory intent) {
        intent.amount = Fixed6.wrap(amount);
        intent.price = Fixed6.wrap(price);
        intent.fee = UFixed6.wrap(solverFee);
        intent.originator = originator;
        intent.solver = solver_;
        intent.collateralization = UFixed6Lib.ZERO;
        intent.common = Common({
            account: trader,
            signer: trader,
            domain: address(market),
            nonce: 0,
            group: 0,
            expiry: type(uint256).max
        });
    }
}
