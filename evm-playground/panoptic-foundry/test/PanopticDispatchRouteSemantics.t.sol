// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {Errors} from 'panoptic-v2-core/contracts/libraries/Errors.sol';
import {TokenId} from 'panoptic-v2-core/contracts/types/TokenId.sol';
import {PositionBalance, PositionBalanceLibrary} from 'panoptic-v2-core/contracts/types/PositionBalance.sol';

contract DispatchRouteHarness {
    uint64 internal immutable expectedPoolId;

    uint8 internal constant BRANCH_MINT = 1;
    uint8 internal constant BRANCH_SETTLE = 2;
    uint8 internal constant BRANCH_BURN = 3;

    mapping(address => mapping(TokenId => PositionBalance)) internal positionBalance;

    constructor(uint64 _expectedPoolId) {
        expectedPoolId = _expectedPoolId;
    }

    function setPositionSize(address owner, TokenId tokenId, uint128 size) external {
        positionBalance[owner][tokenId] = PositionBalanceLibrary.storeBalanceData(
            size,
            0,
            0,
            0,
            0,
            false
        );
    }

    function route(
        address owner,
        TokenId tokenId,
        uint128 inputPositionSize,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        uint8 safeMode,
        int24 startTick,
        int24 finalTick,
        uint24 tickDeltaDispatch
    ) external view returns (uint8 branch, int24 normalizedLow, int24 normalizedHigh) {
        if (tokenId.poolId() != expectedPoolId) revert Errors.WrongPoolId();

        normalizedLow = tickLimitLow;
        normalizedHigh = tickLimitHigh;

        if (safeMode > 1 && normalizedLow > normalizedHigh) {
            (normalizedLow, normalizedHigh) = (normalizedHigh, normalizedLow);
        }

        PositionBalance positionBalanceData = positionBalance[owner][tokenId];

        if (PositionBalance.unwrap(positionBalanceData) == 0) {
            if (safeMode > 2) revert Errors.StaleOracle();
            branch = BRANCH_MINT;
        } else {
            uint128 storedPositionSize = positionBalanceData.positionSize();
            if (storedPositionSize == 0) revert Errors.PositionNotOwned();
            branch = storedPositionSize == inputPositionSize ? BRANCH_SETTLE : BRANCH_BURN;
        }

        uint256 cumulativeTickDelta = uint256(_abs(startTick - finalTick)) + 1;
        if (cumulativeTickDelta > uint256(2 * tickDeltaDispatch)) {
            revert Errors.PriceImpactTooLarge();
        }
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }
}

contract PanopticDispatchRouteSemanticsTest is Test {
    DispatchRouteHarness internal harness;

    address internal owner = address(0xA11CE);
    uint64 internal constant POOL_ID = uint64(0x1234);
    uint8 internal constant BRANCH_MINT = 1;
    uint8 internal constant BRANCH_SETTLE = 2;
    uint8 internal constant BRANCH_BURN = 3;

    function setUp() public {
        harness = new DispatchRouteHarness(POOL_ID);
    }

    function test_route_rejectsWrongPoolId() external {
        TokenId wrongPool = TokenId.wrap(0x9999).addLeg(0, 1, 0, 0, 0, 0, 0, 4);

        vm.expectRevert(Errors.WrongPoolId.selector);
        harness.route(owner, wrongPool, 1, -10, 10, 0, 0, 0, 100);
    }

    function test_route_usesMintBranchForNewPosition() external view {
        (uint8 branch, , ) = harness.route(owner, _token(false, 4), 10, -10, 10, 0, 0, 0, 100);
        assertEq(branch, BRANCH_MINT);
    }

    function test_route_safeModeThreeBlocksNewMint() external {
        vm.expectRevert(Errors.StaleOracle.selector);
        harness.route(owner, _token(false, 4), 10, -10, 10, 3, 0, 0, 100);
    }

    function test_route_reordersTickLimitsInSafeModeTwo() external view {
        (, int24 low, int24 high) = harness.route(owner, _token(false, 4), 10, 50, -50, 2, 0, 0, 100);
        assertEq(low, -50);
        assertEq(high, 50);
    }

    function test_route_keepsTickLimitsOrderOutsideSafeMode() external view {
        (, int24 low, int24 high) = harness.route(owner, _token(false, 4), 10, 50, -50, 1, 0, 0, 100);
        assertEq(low, 50);
        assertEq(high, -50);
    }

    function test_route_usesSettleBranchWhenInputSizeMatchesStoredSize() external {
        TokenId tokenId = _token(true, 2);
        harness.setPositionSize(owner, tokenId, 42);

        (uint8 branch, , ) = harness.route(owner, tokenId, 42, -10, 10, 0, 0, 0, 100);
        assertEq(branch, BRANCH_SETTLE);
    }

    function test_route_usesBurnBranchWhenInputSizeDiffersFromStoredSize() external {
        TokenId tokenId = _token(true, 2);
        harness.setPositionSize(owner, tokenId, 42);

        (uint8 branch, , ) = harness.route(owner, tokenId, 0, -10, 10, 0, 0, 0, 100);
        assertEq(branch, BRANCH_BURN);
    }

    function test_route_priceImpactGuardRevertsWhenRoundTripExceedsThreshold() external {
        vm.expectRevert(Errors.PriceImpactTooLarge.selector);
        harness.route(owner, _token(false, 4), 10, -10, 10, 0, 0, 250, 100);
    }

    function test_route_priceImpactGuardAllowsExactlyAtThreshold() external view {
        (uint8 branch, , ) = harness.route(owner, _token(false, 4), 10, -10, 10, 0, 0, 199, 100);
        assertEq(branch, BRANCH_MINT);
    }

    function _token(bool isLong, int24 width) internal pure returns (TokenId) {
        return
            TokenId.wrap(POOL_ID).addLeg(0, 1, 0, isLong ? 1 : 0, 0, 0, 0, width);
    }
}
