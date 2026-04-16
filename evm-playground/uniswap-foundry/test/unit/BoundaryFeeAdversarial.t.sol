// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import {TestUniswapV3Callee} from "@uniswap/v3-core/contracts/test/TestUniswapV3Callee.sol";

import {MockUniswapV3Factory} from "src/mocks/MockUniswapV3Factory.sol";

/// @notice Adversarial fee-topology tests for boundary-localized flow.
/// @dev These cases are intentionally economic rather than pure safety checks:
/// - boundary pinning is tested as fee-per-capital extraction on organic flow
/// - cross-reverse farming is tested as a self-funded round-trip that should
///   leak value once another LP shares the active liquidity
contract BoundaryFeeAdversarialTest is Test {
    uint24 internal constant FEE = 3000;

    uint128 internal constant WIDE_L = 2e18;
    uint128 internal constant NARROW_L = 2e18;

    address internal constant ATTACKER = address(0xA11CE);
    address internal constant VICTIM = address(0xB0B);
    address internal constant TRADER = address(0xCAFE);

    MockUniswapV3Factory public factoryHelper;
    IUniswapV3Pool internal pool;

    TestERC20 public token0;
    TestERC20 public token1;
    TestUniswapV3Callee internal callee;

    function setUp() public {
        _resetPool(0);
    }

    // ------------------------------------------------------------
    // fixture helpers
    // ------------------------------------------------------------

    function _resetPool(int24 initialTick) internal {
        factoryHelper = new MockUniswapV3Factory();
        callee = new TestUniswapV3Callee();

        (, address poolAddr, TestERC20 t0, TestERC20 t1) =
            factoryHelper.createFactoryAndPool(FEE, TickMath.getSqrtRatioAtTick(initialTick));

        pool = IUniswapV3Pool(poolAddr);
        token0 = t0;
        token1 = t1;

        _fundAndApprove(ATTACKER);
        _fundAndApprove(VICTIM);
        _fundAndApprove(TRADER);
    }

    function _fundAndApprove(address user) internal {
        token0.mint(user, 1e30);
        token1.mint(user, 1e30);

        vm.startPrank(user);
        token0.approve(address(callee), type(uint256).max);
        token1.approve(address(callee), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------
    // readers / helpers
    // ------------------------------------------------------------

    function _sqrtAt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function _positionKey(address owner, int24 lower, int24 upper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, lower, upper));
    }

    function _positionState(address owner, int24 lower, int24 upper)
        internal
        view
        returns (
            uint128 liquidity_,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        return pool.positions(_positionKey(owner, lower, upper));
    }

    function _mint(address owner, int24 lower, int24 upper, uint128 liquidity) internal {
        vm.prank(owner);
        callee.mint(address(pool), owner, lower, upper, liquidity);
    }

    function _mintCost(address owner, int24 lower, int24 upper, uint128 liquidity)
        internal
        returns (uint256 spent0, uint256 spent1)
    {
        uint256 bal0Before = token0.balanceOf(owner);
        uint256 bal1Before = token1.balanceOf(owner);
        _mint(owner, lower, upper, liquidity);
        spent0 = bal0Before - token0.balanceOf(owner);
        spent1 = bal1Before - token1.balanceOf(owner);
    }

    function _swapRightToTick(address trader, int24 targetTick) internal {
        vm.prank(trader);
        callee.swapToHigherSqrtPrice(address(pool), _sqrtAt(targetTick), trader);
    }

    function _swapLeftToTick(address trader, int24 targetTick) internal {
        vm.prank(trader);
        callee.swapToLowerSqrtPrice(address(pool), _sqrtAt(targetTick), trader);
    }

    function _burnZero(address owner, int24 lower, int24 upper) internal {
        vm.prank(owner);
        pool.burn(lower, upper, 0);
    }

    function _burnAll(address owner, int24 lower, int24 upper, uint128 liquidity) internal {
        vm.prank(owner);
        pool.burn(lower, upper, liquidity);
    }

    function _collectAll(address owner, int24 lower, int24 upper) internal returns (uint128 amount0, uint128 amount1) {
        vm.prank(owner);
        return pool.collect(owner, lower, upper, type(uint128).max, type(uint128).max);
    }

    function _nominalBalance(address owner) internal view returns (uint256) {
        return token0.balanceOf(owner) + token1.balanceOf(owner);
    }

    function _crystallizedFees(address owner, int24 lower, int24 upper) internal view returns (uint256) {
        (, , , uint128 owed0, uint128 owed1) = _positionState(owner, lower, upper);
        return uint256(owed0) + uint256(owed1);
    }

    // ------------------------------------------------------------
    // boundary-pinning
    // ------------------------------------------------------------

    function test_boundaryPinning_organicBoundaryFlow_narrowBandHasHigherFeePerCapital() public {
        _resetPool(55);

        int24 victimLower = -600;
        int24 victimUpper = 600;
        int24 attackerLower = 0;
        int24 attackerUpper = 60;

        (uint256 victimSpent0, uint256 victimSpent1) = _mintCost(VICTIM, victimLower, victimUpper, WIDE_L);
        (uint256 attackerSpent0, uint256 attackerSpent1) = _mintCost(ATTACKER, attackerLower, attackerUpper, NARROW_L);

        uint256 victimCapital = victimSpent0 + victimSpent1;
        uint256 attackerCapital = attackerSpent0 + attackerSpent1;

        assertGt(victimCapital, attackerCapital, "wide victim should deploy more capital than narrow attacker");

        // Organic-looking local flow: touch the upper boundary repeatedly but do
        // not fully traverse out of the attacker band.
        for (uint256 i = 0; i < 4; i++) {
            _swapRightToTick(TRADER, 59);
            _swapLeftToTick(TRADER, 54);
        }

        _burnZero(VICTIM, victimLower, victimUpper);
        _burnZero(ATTACKER, attackerLower, attackerUpper);

        (, , , uint128 victimOwed0, uint128 victimOwed1) = _positionState(VICTIM, victimLower, victimUpper);
        (, , , uint128 attackerOwed0, uint128 attackerOwed1) = _positionState(ATTACKER, attackerLower, attackerUpper);

        uint256 victimFees = uint256(victimOwed0) + uint256(victimOwed1);
        uint256 attackerFees = uint256(attackerOwed0) + uint256(attackerOwed1);

        assertGt(victimFees, 0, "victim should earn some boundary-local fees");
        assertGt(attackerFees, 0, "attacker should earn some boundary-local fees");

        // Same active liquidity means fees should be in the same ballpark,
        // while the attacker committed materially less capital.
        assertGt(attackerFees * 100, victimFees * 70, "attacker should not lag far behind on gross fees");
        assertGt(victimCapital * 100, attackerCapital * 120, "narrow band should be materially more capital efficient");
        assertGt(
            attackerFees * victimCapital,
            victimFees * attackerCapital,
            "attacker fee-per-capital should exceed victim fee-per-capital"
        );
    }

    // ------------------------------------------------------------
    // cross-reverse-farming
    // ------------------------------------------------------------

    function test_crossReverseFarming_selfFundedRoundTrip_isNetNegative() public {
        _resetPool(0);
        (
            uint256 attackerBeforeMint,
            uint256 attackerAfter,
            uint256 grossLpFees,
            uint256 victimGrossFees
        ) = _runSelfFundedCrossReverseScenario(20e18, 1e18);

        assertGt(grossLpFees, 0, "attacker should recover some LP fees from the round-trip");
        assertGt(victimGrossFees, 0, "victim should also capture fees from the attacker-funded flow");
        assertLt(attackerAfter, attackerBeforeMint, "self-funded crossing cycle should be net negative");
    }

    function _runSelfFundedCrossReverseScenario(uint128 victimL, uint128 attackerL)
        internal
        returns (
            uint256 attackerBeforeMint,
            uint256 attackerAfter,
            uint256 grossLpFees,
            uint256 victimGrossFees
        )
    {
        attackerBeforeMint = _nominalBalance(ATTACKER);

        _mint(VICTIM, -600, 600, victimL);
        (uint256 spentLeft0, uint256 spentLeft1) = _mintCost(ATTACKER, 0, 60, attackerL);
        (uint256 spentRight0, uint256 spentRight1) = _mintCost(ATTACKER, 60, 120, attackerL);
        require(spentLeft0 + spentLeft1 + spentRight0 + spentRight1 > 0, "attacker capital should be nonzero");

        _swapRightToTick(ATTACKER, 119);
        _swapLeftToTick(ATTACKER, 0);

        _burnZero(VICTIM, -600, 600);
        _burnZero(ATTACKER, 0, 60);
        _burnZero(ATTACKER, 60, 120);

        grossLpFees = _crystallizedFees(ATTACKER, 0, 60) + _crystallizedFees(ATTACKER, 60, 120);
        victimGrossFees = _crystallizedFees(VICTIM, -600, 600);

        _burnAll(ATTACKER, 0, 60, attackerL);
        _burnAll(ATTACKER, 60, 120, attackerL);
        _collectAll(ATTACKER, 0, 60);
        _collectAll(ATTACKER, 60, 120);

        attackerAfter = _nominalBalance(ATTACKER);
    }
}
