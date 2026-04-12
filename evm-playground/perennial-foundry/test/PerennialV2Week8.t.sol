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


contract PerennialV2Week8Test is BaseMarketReview {
    function test_plainTakerCheckpoint_reconcilesToLocalCollateralDelta() public {
        // Type: postcondition / reconciliation
        // Hypothesis: after a plain taker update and settlement, the observed local
        // collateral delta should be fully explainable by checkpoint transfer,
        // collateral, trade fee, and settlement fee fields.

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
        // Type: postcondition / decomposition
        // Hypothesis: a guaranteed intent settlement should decompose cleanly into
        // guaranteed price override, ordinary trade fee, and externally visible
        // claimable outputs without unexplained residual.
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