// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {CollateralTrackerV2} from 'panoptic-v2-core/contracts/CollateralTracker.sol';
import {RiskEngine} from 'panoptic-v2-core/contracts/RiskEngine.sol';
import {Errors} from 'panoptic-v2-core/contracts/libraries/Errors.sol';
import {TokenId} from 'panoptic-v2-core/contracts/types/TokenId.sol';
import {ERC20S} from 'panoptic-v2-core/test/foundry/testUtils/ERC20S.sol';
import {ClonesWithImmutableArgs} from 'clones-with-immutable-args/ClonesWithImmutableArgs.sol';

contract PanopticPoolMock {
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
}

contract PanopticCollateralVirtualSharesTest is Test {
    using ClonesWithImmutableArgs for address;

    CollateralTrackerV2 internal tracker;
    RiskEngine internal riskEngine;
    ERC20S internal token0;
    ERC20S internal token1;
    PanopticPoolMock internal pool;
    address internal user = address(0xB0B);
    uint256 internal constant DELEGATION = type(uint248).max;

    function setUp() public {
        token0 = new ERC20S('Token 0', 'TK0', 18);
        token1 = new ERC20S('Token 1', 'TK1', 18);
        riskEngine = new RiskEngine(10_000_000, 10_000_000, address(0), address(0));
        pool = new PanopticPoolMock();
        tracker = _deployTracker(
            address(pool),
            true,
            address(token0),
            address(token0),
            address(token1),
            address(riskEngine)
        );
        tracker.initialize();
    }

    function test_initialize_setsExpectedVirtualShareBaseline() external view {
        assertEq(tracker.totalAssets(), 1);
        assertEq(tracker.totalSupply(), 1_000_000);
        assertEq(tracker.convertToShares(1), 1_000_000);
        assertEq(tracker.convertToAssets(1_000_000), 1);
    }

    function test_previewFunctions_matchInitialVirtualBaseline() external view {
        assertEq(tracker.previewDeposit(3), 3_000_000);
        assertEq(tracker.previewMint(3_000_000), 3);
        assertEq(tracker.previewWithdraw(3), 3_000_000);
        assertEq(tracker.previewRedeem(3_000_000), 3);
        assertEq(tracker.maxDeposit(user), type(uint104).max);
        assertEq(tracker.maxMint(user), tracker.convertToShares(type(uint104).max));
    }

    function test_delegateAndRevoke_doNotChangeTotalSupply() external {
        uint256 supplyBefore = tracker.totalSupply();

        pool.delegateTracker(address(tracker), user);
        assertEq(tracker.balanceOf(user), DELEGATION);
        assertEq(tracker.totalSupply(), supplyBefore);

        pool.revokeTracker(address(tracker), user);
        assertEq(tracker.balanceOf(user), 0);
        assertEq(tracker.totalSupply(), supplyBefore);
    }

    function test_revokeWithoutDelegation_reverts() external {
        vm.expectRevert();
        pool.revokeTracker(address(tracker), user);
    }

    function test_refundMovesDelegatedShares_withoutChangingTotalSupply() external {
        pool.delegateTracker(address(tracker), user);

        uint256 supplyBefore = tracker.totalSupply();
        uint256 balanceBefore = tracker.balanceOf(user);
        uint256 transferAssets = 1;
        uint256 transferShares = tracker.convertToShares(transferAssets);

        pool.refundTracker(address(tracker), user, address(this), int256(transferAssets));

        assertEq(tracker.balanceOf(user), balanceBefore - transferShares);
        assertEq(tracker.balanceOf(address(this)), transferShares);
        assertEq(tracker.totalSupply(), supplyBefore);
    }

    function test_revokeAfterDelegatedBalanceConsumption_reverts() external {
        pool.delegateTracker(address(tracker), user);
        pool.refundTracker(address(tracker), user, address(this), 1);

        vm.expectRevert();
        pool.revokeTracker(address(tracker), user);
    }

    function test_deposit_mintsPreviewSharesAndUpdatesTrackedAssets() external {
        uint256 assets = 5;
        uint256 expectedShares = tracker.previewDeposit(assets);

        token0.mint(address(this), assets);
        token0.approve(address(tracker), assets);

        uint256 mintedShares = tracker.deposit(assets, user);

        assertEq(mintedShares, expectedShares);
        assertEq(tracker.balanceOf(user), expectedShares);
        assertEq(tracker.totalAssets(), 1 + assets);
        assertEq(tracker.totalSupply(), 1_000_000 + expectedShares);
        assertEq(token0.balanceOf(address(pool)), assets);
    }

    function test_withdraw_withoutOpenPositions_returnsUnderlyingAndBurnsPreviewShares() external {
        uint256 assets = 5;
        token0.mint(address(this), assets);
        token0.approve(address(tracker), assets);
        tracker.deposit(assets, user);
        pool.approveToken(address(token0), address(tracker), type(uint256).max);

        uint256 withdrawAssets = 2;
        uint256 expectedShares = tracker.previewWithdraw(withdrawAssets);
        uint256 userSharesBefore = tracker.balanceOf(user);

        vm.prank(user);
        uint256 burnedShares = tracker.withdraw(withdrawAssets, user, user);

        assertEq(burnedShares, expectedShares);
        assertEq(tracker.balanceOf(user), userSharesBefore - expectedShares);
        assertEq(tracker.totalAssets(), 1 + assets - withdrawAssets);
        assertEq(token0.balanceOf(user), withdrawAssets);
    }

    function test_redeem_withoutOpenPositions_returnsUnderlyingByConversion() external {
        uint256 assets = 7;
        token0.mint(address(this), assets);
        token0.approve(address(tracker), assets);
        tracker.deposit(assets, user);
        pool.approveToken(address(token0), address(tracker), type(uint256).max);

        uint256 redeemShares = tracker.balanceOf(user) / 2;
        uint256 expectedAssets = tracker.previewRedeem(redeemShares);

        vm.prank(user);
        uint256 redeemedAssets = tracker.redeem(redeemShares, user, user);

        assertEq(redeemedAssets, expectedAssets);
        assertEq(token0.balanceOf(user), expectedAssets);
    }

    function test_mint_mintsRequestedSharesAndPullsPreviewAssets() external {
        uint256 requestedShares = 2_500_000;
        uint256 expectedAssets = tracker.previewMint(requestedShares);

        token0.mint(address(this), expectedAssets);
        token0.approve(address(tracker), expectedAssets);

        uint256 depositedAssets = tracker.mint(requestedShares, user);

        assertEq(depositedAssets, expectedAssets);
        assertEq(tracker.balanceOf(user), requestedShares);
        assertEq(tracker.totalAssets(), 1 + expectedAssets);
        assertEq(token0.balanceOf(address(pool)), expectedAssets);
    }

    function test_withdraw_byApprovedOperator_consumesAllowance() external {
        uint256 assets = 6;
        token0.mint(address(this), assets);
        token0.approve(address(tracker), assets);
        tracker.deposit(assets, user);
        pool.approveToken(address(token0), address(tracker), type(uint256).max);

        uint256 withdrawAssets = 2;
        uint256 expectedShares = tracker.previewWithdraw(withdrawAssets);

        vm.prank(user);
        tracker.approve(address(this), expectedShares);

        tracker.withdraw(withdrawAssets, user, user);

        assertEq(tracker.allowance(user, address(this)), 0);
        assertEq(token0.balanceOf(user), withdrawAssets);
    }

    function test_redeem_byApprovedOperator_consumesAllowance() external {
        uint256 assets = 6;
        token0.mint(address(this), assets);
        token0.approve(address(tracker), assets);
        tracker.deposit(assets, user);
        pool.approveToken(address(token0), address(tracker), type(uint256).max);

        uint256 redeemShares = tracker.balanceOf(user) / 3;
        uint256 expectedAssets = tracker.previewRedeem(redeemShares);

        vm.prank(user);
        tracker.approve(address(this), redeemShares);

        tracker.redeem(redeemShares, user, user);

        assertEq(tracker.allowance(user, address(this)), 0);
        assertEq(token0.balanceOf(user), expectedAssets);
    }

    function test_maxWithdrawAndMaxRedeem_areZeroForFreshAccount() external view {
        assertEq(tracker.maxWithdraw(user), 0);
        assertEq(tracker.maxRedeem(user), 0);
    }

    function test_deposit_zeroAssetsReverts() external {
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        tracker.deposit(0, user);
    }

    function test_mint_zeroSharesReverts() external {
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        tracker.mint(0, user);
    }

    function test_deposit_aboveUint104Reverts() external {
        vm.expectRevert(Errors.DepositTooLarge.selector);
        tracker.deposit(uint256(type(uint104).max) + 1, user);
    }

    function test_withdraw_aboveMaxWithdrawReverts() external {
        uint256 assets = 3;
        token0.mint(address(this), assets);
        token0.approve(address(tracker), assets);
        tracker.deposit(assets, user);

        vm.prank(user);
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        tracker.withdraw(assets + 1, user, user);
    }

    function test_redeem_fromFreshAccountReverts() external {
        vm.prank(user);
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        tracker.redeem(1, user, user);
    }

    function test_operatorWithdraw_withUnlimitedAllowanceDoesNotDecreaseApproval() external {
        uint256 assets = 6;
        token0.mint(address(this), assets);
        token0.approve(address(tracker), assets);
        tracker.deposit(assets, user);
        pool.approveToken(address(token0), address(tracker), type(uint256).max);

        vm.prank(user);
        tracker.approve(address(this), type(uint256).max);

        tracker.withdraw(1, user, user);

        assertEq(tracker.allowance(user, address(this)), type(uint256).max);
    }

    function _deployTracker(
        address panopticPool,
        bool underlyingIsToken0,
        address underlyingToken,
        address _token0,
        address _token1,
        address _riskEngine
    ) internal returns (CollateralTrackerV2 deployed) {
        address trackerReference = address(new CollateralTrackerV2());
        deployed = CollateralTrackerV2(
            trackerReference.clone2(
                abi.encodePacked(
                    panopticPool,
                    underlyingIsToken0,
                    underlyingToken,
                    _token0,
                    _token1,
                    _riskEngine,
                    address(0),
                    uint24(3_000)
                )
            )
        );
    }
}
