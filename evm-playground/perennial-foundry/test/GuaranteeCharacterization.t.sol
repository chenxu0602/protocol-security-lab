// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { BaseMarketReview } from "./BaseMarketReview.t.sol";
import { Intent } from "perennial-v2/packages/core/contracts/types/Intent.sol";
import { Checkpoint } from "perennial-v2/packages/core/contracts/types/Checkpoint.sol";
import { Guarantee } from "perennial-v2/packages/core/contracts/types/Guarantee.sol";
import { Common } from "@equilibria/root/verifier/types/Common.sol";
import { Fixed6, Fixed6Lib } from "@equilibria/root/number/types/Fixed6.sol";
import { UFixed6, UFixed6Lib } from "@equilibria/root/number/types/UFixed6.sol";

contract GuaranteeCharacterizationTest is BaseMarketReview {
    function test_guaranteePriceOverride_matchesSignedGuaranteedQuantity() public {
        _relaxRiskForNoCollateralTests();
        _openAndSettleMakerLiquidity(lp, 10e6);
        _enableSelfSigner(taker);
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 0);
        _advanceOracle(1900e6);

        Intent memory intent = _intent(taker, maker, 1e6, 1900e6);

        vm.prank(maker);
        market.update(maker, intent, "");

        uint256 orderId = market.locals(taker).currentId;
        uint256 orderTimestamp = market.pendingOrders(taker, orderId).timestamp;

        _advanceOracle(2000e6);
        market.settle(taker);

        Checkpoint memory checkpoint = market.checkpoints(taker, orderTimestamp);
        int256 expectedPriceOverride = 1e6 * (2000e6 - 1900e6) / 1e6;

        assertEq(Fixed6.unwrap(checkpoint.collateral), expectedPriceOverride, "trader checkpoint collateral should equal guarantee price override");
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), 0, "trade fee should be zero");
        assertEq(UFixed6.unwrap(checkpoint.settlementFee), 0, "settlement fee should be zero");
    }

    function test_guaranteedSettlementFeeExclusion_zeroesOrdinarySettlementFee() public {
        _relaxRiskForNoCollateralTests();
        _openAndSettleMakerLiquidity(lp, 10e6);
        _enableSelfSigner(taker);
        _setOracleReceipt(5e6, 0);
        _setMarketFees(0, 0);

        vm.prank(taker2);
        market.update(taker2, Fixed6.wrap(1e6), address(0));

        uint256 directOrderId = market.locals(taker2).currentId;
        uint256 directOrderTimestamp = market.pendingOrders(taker2, directOrderId).timestamp;

        Intent memory intent = _intent(taker, maker, 1e6, 2000e6);
        vm.prank(maker);
        market.update(maker, intent, "");

        uint256 guaranteedOrderId = market.locals(taker).currentId;
        uint256 guaranteedOrderTimestamp = market.pendingOrders(taker, guaranteedOrderId).timestamp;
        Guarantee memory guaranteedLocal = market.guarantees(taker, guaranteedOrderId);

        assertEq(guaranteedLocal.orders, 1, "guarantee should exempt one order count");

        _advanceOracle(2000e6);
        market.settle(taker2);
        market.settle(taker);

        Checkpoint memory directCheckpoint = market.checkpoints(taker2, directOrderTimestamp);
        Checkpoint memory guaranteedCheckpoint = market.checkpoints(taker, guaranteedOrderTimestamp);

        assertEq(UFixed6.unwrap(directCheckpoint.settlementFee), 5e6, "ordinary taker order should pay settlement fee");
        assertEq(UFixed6.unwrap(guaranteedCheckpoint.settlementFee), 0, "guaranteed order count should not pay ordinary settlement fee");
    }

    function test_guaranteedTakerFeeExclusion_exemptsCounterpartyButNotTrader() public {
        _relaxRiskForNoCollateralTests();
        _openAndSettleMakerLiquidity(lp, 10e6);
        _depositAndSettle(maker, 100e6);
        _depositAndSettle(taker, 100e6);
        _enableSelfSigner(taker);
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 10_000); // 1%

        Intent memory intent = _intent(taker, maker, 1e6, 2000e6);

        vm.prank(maker);
        market.update(maker, intent, "");

        uint256 makerOrderId = market.locals(maker).currentId;
        uint256 takerOrderId = market.locals(taker).currentId;
        uint256 makerOrderTimestamp = market.pendingOrders(maker, makerOrderId).timestamp;
        uint256 takerOrderTimestamp = market.pendingOrders(taker, takerOrderId).timestamp;

        Guarantee memory makerGuarantee = market.guarantees(maker, makerOrderId);
        Guarantee memory takerGuarantee = market.guarantees(taker, takerOrderId);

        assertEq(UFixed6.unwrap(makerGuarantee.takerFee), 1e6, "counterparty leg should exempt all ordinary taker fee quantity");
        assertEq(UFixed6.unwrap(takerGuarantee.takerFee), 0, "trader leg should not exempt ordinary taker fee quantity");

        _advanceOracle(2000e6);
        market.settle(maker);
        market.settle(taker);

        Checkpoint memory makerCheckpoint = market.checkpoints(maker, makerOrderTimestamp);
        Checkpoint memory takerCheckpoint = market.checkpoints(taker, takerOrderTimestamp);

        assertEq(Fixed6.unwrap(makerCheckpoint.tradeFee), 0, "counterparty leg should not pay ordinary taker fee");
        assertEq(Fixed6.unwrap(takerCheckpoint.tradeFee), 20e6, "trader leg should pay ordinary taker fee");
    }

    function test_guaranteePriceOverride_aggregatesAcrossSameInterval() public {
        _relaxRiskForNoCollateralTests();
        _disableFundingAndInterest();
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 0);

        _openAndSettleMakerLiquidity(lp, 10e6);
        _enableSelfSigner(taker);
        _depositAndSettle(maker, 500e6);
        _mockTransferFromSuccess();
        vm.prank(taker);
        market.update(taker, Fixed6Lib.ZERO, Fixed6.wrap(100e6), address(0));
        _advanceOracle(2000e6);
        market.settle(taker);
        Fixed6 collateralBefore = market.locals(taker).collateral;
        _advanceOracle(1900e6);

        vm.prank(maker);
        market.update(maker, _intent(taker, maker, 1e6, 1900e6), "");
        uint256 firstOrderId = market.locals(taker).currentId;

        vm.prank(maker);
        market.update(maker, _intent(taker, maker, 1e6, 1950e6), "");

        uint256 aggregatedOrderId = market.locals(taker).currentId;
        uint256 aggregatedTimestamp = market.pendingOrders(taker, aggregatedOrderId).timestamp;
        Guarantee memory aggregatedGuarantee = market.guarantees(taker, aggregatedOrderId);

        assertEq(firstOrderId, aggregatedOrderId, "same-account guaranteed fills should aggregate into one local pending order for the interval");
        assertEq(Fixed6.unwrap(aggregatedGuarantee.notional), 3850e6, "aggregated guarantee notional should sum signed quantity times guaranteed price");

        _advanceOracle(2000e6);
        market.settle(taker);

        Checkpoint memory checkpoint = market.checkpoints(taker, aggregatedTimestamp);
        assertEq(Fixed6.unwrap(market.locals(taker).collateral.sub(collateralBefore)), 150e6, "aggregated guaranteed price override should equal the sum of both fill overrides");
        assertEq(Fixed6.unwrap(checkpoint.collateral.sub(collateralBefore)), 150e6, "checkpoint collateral should carry the baseline collateral plus the summed override");
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), 0, "with market fees disabled, aggregated guarantee path should isolate price override");
        assertEq(UFixed6.unwrap(checkpoint.settlementFee), 0, "aggregated guaranteed order count should remain settlement-fee exempt");
    }

    function test_guaranteePriceOverride_survivesInvalidationPath() public {
        _relaxRiskForNoCollateralTests();
        _disableFundingAndInterest();
        _setOracleReceipt(0, 0);
        _setMarketFees(0, 0);

        _openAndSettleMakerLiquidity(lp, 10e6);
        _enableSelfSigner(taker);
        _depositAndSettle(maker, 200e6);
        _advanceOracle(1900e6);

        vm.prank(maker);
        market.update(maker, _intent(taker, maker, 1e6, 1900e6), "");

        uint256 orderId = market.locals(taker).currentId;
        uint256 orderTimestamp = market.pendingOrders(taker, orderId).timestamp;

        _advanceOracleWithValidity(2000e6, false);
        market.settle(taker);

        Checkpoint memory checkpoint = market.checkpoints(taker, orderTimestamp);
        assertEq(Fixed6.unwrap(checkpoint.collateral), 100e6, "invalidating the non-guarantee portion should preserve the guaranteed price override");
        assertEq(UFixed6.unwrap(checkpoint.settlementFee), 0, "guaranteed order should remain settlement-fee exempt through invalidation");
    }

    function test_sameAccountMixedGuaranteedAndOrdinaryFlow_keepsFeeDomainsSeparated() public {
        _relaxRiskForNoCollateralTests();
        _disableFundingAndInterest();
        _setOracleReceipt(5e6, 0);
        _setMarketFees(0, 10_000);

        _openAndSettleMakerLiquidity(lp, 10e6);
        _enableSelfSigner(taker);
        _depositAndSettle(maker, 500e6);
        _mockTransferFromSuccess();
        vm.prank(taker);
        market.update(taker, Fixed6Lib.ZERO, Fixed6.wrap(100e6), address(0));
        _advanceOracle(2000e6);
        market.settle(taker);
        Fixed6 collateralBefore = market.locals(taker).collateral;
        _advanceOracle(1900e6);

        vm.prank(taker);
        market.update(taker, Fixed6.wrap(1e6), address(0));

        vm.prank(maker);
        market.update(maker, _intent(taker, maker, 1e6, 1900e6), "");

        uint256 mixedOrderId = market.locals(taker).currentId;
        uint256 mixedTimestamp = market.pendingOrders(taker, mixedOrderId).timestamp;
        Guarantee memory mixedGuarantee = market.guarantees(taker, mixedOrderId);

        assertEq(mixedGuarantee.orders, 1, "only the guaranteed sub-order should be settlement-fee exempt");
        assertEq(UFixed6.unwrap(mixedGuarantee.takerFee), 0, "the trader guaranteed leg should not exempt ordinary taker fee");

        _advanceOracle(2000e6);
        market.settle(taker);

        Checkpoint memory checkpoint = market.checkpoints(taker, mixedTimestamp);
        Fixed6 collateralDelta = market.locals(taker).collateral.sub(collateralBefore);

        assertEq(Fixed6.unwrap(checkpoint.collateral.sub(collateralBefore)), 100e6, "guaranteed price override should remain isolated inside checkpoint collateral");
        assertEq(Fixed6.unwrap(checkpoint.tradeFee), 40e6, "ordinary and guaranteed trader taker flow should both pay ordinary taker fee");
        assertEq(UFixed6.unwrap(checkpoint.settlementFee), 5e6, "only the ordinary order count should pay settlement fee");
        assertEq(Fixed6.unwrap(collateralDelta), 55e6, "net local effect should be guarantee override minus two taker fees minus one settlement fee");
    }

    function _intent(address trader, address solver_, int256 amount, int256 price) internal view returns (Intent memory) {
        return Intent({
            amount: Fixed6.wrap(amount),
            price: Fixed6.wrap(price),
            fee: UFixed6Lib.ZERO,
            originator: address(0),
            solver: solver_,
            collateralization: UFixed6Lib.ZERO,
            common: Common({
                account: trader,
                signer: trader,
                domain: address(market),
                nonce: 0,
                group: 0,
                expiry: type(uint256).max
            })
        });
    }
}
