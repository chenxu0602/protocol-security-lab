// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {CollateralTrackerV2} from 'panoptic-v2-core/contracts/CollateralTracker.sol';
import {RiskEngine} from 'panoptic-v2-core/contracts/RiskEngine.sol';
import {Errors} from 'panoptic-v2-core/contracts/libraries/Errors.sol';
import {RiskParameters, RiskParametersLibrary} from 'panoptic-v2-core/contracts/types/RiskParameters.sol';
import {TokenId} from 'panoptic-v2-core/contracts/types/TokenId.sol';
import {ERC20S} from 'panoptic-v2-core/test/foundry/testUtils/ERC20S.sol';
import {ClonesWithImmutableArgs} from 'clones-with-immutable-args/ClonesWithImmutableArgs.sol';

contract SettlementPoolMock {
    function numberOfLegs(address) external pure returns (uint256) {
        return 0;
    }

    function validateCollateralWithdrawable(
        address,
        TokenId[] calldata,
        bool
    ) external pure {}

    function approveToken(address token, address spender, uint256 amount) external {
        ERC20S(token).approve(spender, amount);
    }

    function delegateTracker(address tracker, address delegatee) external {
        CollateralTrackerV2(tracker).delegate(delegatee);
    }

    function revokeTracker(address tracker, address delegatee) external {
        CollateralTrackerV2(tracker).revoke(delegatee);
    }

    function refundTracker(address tracker, address refunder, address refundee, int256 assets) external {
        CollateralTrackerV2(tracker).refund(refunder, refundee, assets);
    }

    function settleMintTracker(
        address tracker,
        address optionOwner,
        int128 longAmount,
        int128 shortAmount,
        int128 ammDeltaAmount,
        RiskParameters riskParameters
    ) external returns (uint32 utilization, int128 tokenPaid) {
        return
            CollateralTrackerV2(tracker).settleMint(
                optionOwner,
                longAmount,
                shortAmount,
                ammDeltaAmount,
                riskParameters
            );
    }

    function settleBurnTracker(
        address tracker,
        address optionOwner,
        int128 longAmount,
        int128 shortAmount,
        int128 ammDeltaAmount,
        int128 realizedPremium,
        RiskParameters riskParameters
    ) external returns (int128 tokenPaid) {
        return
            CollateralTrackerV2(tracker).settleBurn(
                optionOwner,
                longAmount,
                shortAmount,
                ammDeltaAmount,
                realizedPremium,
                riskParameters
            );
    }
}

contract PanopticSettlementPoCsTest is Test {
    using ClonesWithImmutableArgs for address;

    uint256 internal constant DECIMALS = 10_000;
    uint256 internal constant DELEGATION = type(uint248).max;

    ERC20S internal token0;
    ERC20S internal token1;
    RiskEngine internal riskEngine;
    SettlementPoolMock internal pool;

    address internal owner = address(0xA11CE);
    address internal attacker = address(0xB0B);
    address internal lp = address(0xCAFE);
    address internal builder = address(0xB17D);

    function setUp() public {
        token0 = new ERC20S('Token 0', 'TK0', 18);
        token1 = new ERC20S('Token 1', 'TK1', 18);
        riskEngine = new RiskEngine(10_000_000, 10_000_000, address(0), address(0));
        pool = new SettlementPoolMock();
    }

    function test_refund_sameRefunderAndRefundee_isValueNeutralEvenWithDelegation() external {
        CollateralTrackerV2 tracker = _deployTracker();

        pool.delegateTracker(address(tracker), owner);
        uint256 supplyBefore = tracker.totalSupply();
        uint256 balanceBefore = tracker.balanceOf(owner);

        pool.refundTracker(address(tracker), owner, owner, 1);

        assertEq(balanceBefore, DELEGATION);
        assertEq(tracker.balanceOf(owner), balanceBefore);
        assertEq(tracker.totalSupply(), supplyBefore);
    }

    function test_settleBurn_premiumOnlyPathStillChargesCommission() external {
        CollateralTrackerV2 tracker = _deployTracker();
        RiskParameters riskParameters = _riskParameters(0, 1_000, 0);

        int128 realizedPremium = 100;
        int128 tokenPaid = pool.settleBurnTracker(
            address(tracker),
            owner,
            0,
            0,
            0,
            realizedPremium,
            riskParameters
        );

        // Premium-only settlement should still charge 10% commission on the realized premium.
        assertEq(tokenPaid, -90);
        assertEq(tracker.balanceOf(owner), 90_000_000);
    }

    function test_settleMint_feeRecipientZeroBurnsCommissionShares() external {
        CollateralTrackerV2 tracker = _deployTracker();
        _deposit(tracker, lp, 1_000);
        _deposit(tracker, owner, 1_000);

        uint256 totalAssetsBefore = tracker.totalAssets();
        uint256 totalSupplyBefore = tracker.totalSupply();

        RiskParameters burnToPlps = _riskParameters(1_000, 0, 0);

        int128 longAmount = 100;
        uint256 commissionFee = 10;
        uint256 expectedCommissionShares = _sharesRoundedUp(
            commissionFee,
            totalSupplyBefore,
            totalAssetsBefore
        );

        pool.settleMintTracker(address(tracker), owner, longAmount, 0, 0, burnToPlps);

        assertEq(totalSupplyBefore - tracker.totalSupply(), expectedCommissionShares);
    }

    function test_jitEntrantCapturesMoreUpliftWhenCommissionIsBurnedToPlps() external {
        CollateralTrackerV2 burnTracker = _deployTracker();
        CollateralTrackerV2 transferTracker = _deployTracker();

        _seedJitScenario(burnTracker);
        _seedJitScenario(transferTracker);

        uint256 burnValueBefore = burnTracker.previewRedeem(burnTracker.balanceOf(attacker));
        uint256 transferValueBefore = transferTracker.previewRedeem(transferTracker.balanceOf(attacker));

        uint256 burnSupplyBefore = burnTracker.totalSupply();
        uint256 transferSupplyBefore = transferTracker.totalSupply();

        RiskParameters burnToPlps = _riskParameters(1_000, 0, 0);
        RiskParameters transferToBuilder = _riskParameters(1_000, 0, uint128(uint160(builder)));

        pool.settleMintTracker(address(burnTracker), owner, 100, 0, 0, burnToPlps);
        pool.settleMintTracker(address(transferTracker), owner, 100, 0, 0, transferToBuilder);

        uint256 burnValueAfter = burnTracker.previewRedeem(burnTracker.balanceOf(attacker));
        uint256 transferValueAfter = transferTracker.previewRedeem(transferTracker.balanceOf(attacker));

        uint256 burnUplift = burnValueAfter - burnValueBefore;
        uint256 transferUplift = transferValueAfter - transferValueBefore;

        assertGt(burnUplift, transferUplift);
        assertLt(burnTracker.totalSupply(), transferTracker.totalSupply());

        // With a dominant same-block entrant, most of the burn-based uplift accrues to the entrant.
        assertEq(burnSupplyBefore - burnTracker.totalSupply(), 10_000_000);
        assertEq(transferSupplyBefore - transferTracker.totalSupply(), 0);
    }

    function _seedJitScenario(CollateralTrackerV2 tracker) internal {
        _deposit(tracker, lp, 1_000);
        _deposit(tracker, owner, 1_000);
        _deposit(tracker, attacker, 1_000_000);
    }

    function _deposit(CollateralTrackerV2 tracker, address from, uint256 assets) internal {
        token0.mint(from, assets);
        vm.startPrank(from);
        token0.approve(address(tracker), assets);
        tracker.deposit(assets, from);
        vm.stopPrank();
    }

    function _riskParameters(
        uint16 notionalFee,
        uint16 premiumFee,
        uint128 feeRecipient
    ) internal pure returns (RiskParameters) {
        uint16 protocolSplit = feeRecipient == 0 ? uint16(0) : uint16(DECIMALS / 2);
        uint16 builderSplit = feeRecipient == 0 ? uint16(0) : uint16(DECIMALS / 2);

        return
            RiskParametersLibrary.storeRiskParameters(
                0,
                notionalFee,
                premiumFee,
                protocolSplit,
                builderSplit,
                0,
                0,
                0,
                4,
                feeRecipient
            );
    }

    function _sharesRoundedUp(
        uint256 assets,
        uint256 totalSupply,
        uint256 totalAssets
    ) internal pure returns (uint256) {
        return (assets * totalSupply + totalAssets - 1) / totalAssets;
    }

    function _deployTracker() internal returns (CollateralTrackerV2 deployed) {
        address trackerReference = address(new CollateralTrackerV2());
        deployed = CollateralTrackerV2(
            trackerReference.clone2(
                abi.encodePacked(
                    address(pool),
                    true,
                    address(token0),
                    address(token0),
                    address(token1),
                    address(riskEngine),
                    address(0),
                    uint24(3_000)
                )
            )
        );
        deployed.initialize();
    }
}
