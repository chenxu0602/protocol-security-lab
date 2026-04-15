// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import {TestUniswapV3Callee} from "@uniswap/v3-core/contracts/test/TestUniswapV3Callee.sol";

import {MockUniswapV3Factory} from "src/mocks/MockUniswapV3Factory.sol";

/// @notice Fee-growth settlement regression tests.
/// @dev This file checks one narrow invariant:
/// earned fee growth inside a position must remain recoverable after the
/// position moves below range, stays in range, moves above range, or lands
/// exactly on a boundary tick.
contract FeeGrowthInsideBoundaryTest is Test {
    uint24 internal constant FEE = 3000;
    int24   internal constant SPACING = 60;

    uint128 internal constant L = 1e18;

    MockUniswapV3Factory public factoryHelper;
    IUniswapV3Pool internal pool;

    TestERC20 public token0;
    TestERC20 public token1;
    TestUniswapV3Callee internal callee;

    // ------------------------------------------------------------
    // fixture helpers
    // ------------------------------------------------------------

    function setUp() public {
        factoryHelper = new MockUniswapV3Factory();
        callee = new TestUniswapV3Callee();

        (, address poolAddr, TestERC20 t0, TestERC20 t1) = 
            factoryHelper.createFactoryAndPool(FEE, TickMath.getSqrtRatioAtTick(0));

        pool = IUniswapV3Pool(poolAddr);
        token0 = t0;
        token1 = t1;

        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);

        token0.approve(address(callee), type(uint256).max);
        token1.approve(address(callee), type(uint256).max);
    }

    // ------------------------------------------------------------
    // state readers
    // ------------------------------------------------------------

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = pool.slot0();
    }

    function _activeLiquidity() internal view returns (uint128) {
        return pool.liquidity();
    }

    // ------------------------------------------------------------
    // pool action helpers
    // ------------------------------------------------------------

    function _burnZero(int24 lower, int24 upper) internal {
        pool.burn(lower, upper, 0);
    }

    function _sqrtAt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function _mint(int24 lower, int24 upper, uint128 liquidity) internal {
        callee.mint(address(pool), address(this), lower, upper, liquidity);
    }

    function _swapRightToTick(int24 targetTick) internal {
        callee.swapToHigherSqrtPrice(address(pool), _sqrtAt(targetTick), address(this));
    }

    function _swapLeftToTick(int24 targetTick) internal {
        callee.swapToLowerSqrtPrice(address(pool), _sqrtAt(targetTick), address(this));
    }   

    // ------------------------------------------------------------
    // position helpers
    // ------------------------------------------------------------

    function _positionKey(int24 lower, int24 upper) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), lower, upper));
    }

    function _positionState(int24 lower, int24 upper) internal view returns (
        uint128 liquidity_, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1
    ) {
        return pool.positions(_positionKey(lower, upper));
    }

    // ------------------------------------------------------------
    // assertion / reset helpers
    // ------------------------------------------------------------

    function _assertCurrentTick(int24 expectedTick) internal view {
        (, int24 tick) = _slot0();
        assertEq(int256(tick), int256(expectedTick), "unexpected current tick");
    }

    function _assertHasCrystallizedFeeState(
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1,
        string memory message
    ) internal pure {
        assertTrue(
            feeGrowthInside0LastX128 > 0 || feeGrowthInside1LastX128 > 0 || tokensOwed0 > 0 || tokensOwed1 > 0,
            message
        );
    }

    function _resetSingleRange(int24 lower, int24 upper, uint128 liquidity) internal {
        setUp();
        _mint(lower, upper, liquidity);
    }

    // ------------------------------------------------------------
    // 1. In-range fee accrual should crystallize into nonzero fee state
    // ------------------------------------------------------------

    function test_inRange_burnZero_crystallizesFees() public {
        int24 lower = -60;
        int24 upper = 60;

        _mint(lower, upper, L);

        _swapRightToTick(30);
        _burnZero(lower, upper);

        (
            uint128 liq,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = _positionState(lower, upper);

        assertEq(uint256(liq), uint256(L), "unexpected position liquidity");
        _assertHasCrystallizedFeeState(
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128,
            tokensOwed0,
            tokensOwed1,
            "expected crystallized in-range fee state"
        );
    }

    // ------------------------------------------------------------
    // 2. Below range: burn(0) should not destroy previously earned entitlement
    // ------------------------------------------------------------

    function test_belowRange_burnZero_preservesPreviouslyEarnedEntitlement() public {
        int24 lower = -60;
        int24 upper = 60;

        _mint(lower, upper, L);

        _swapRightToTick(30);
        _swapLeftToTick(-60);

        _assertCurrentTick(-61);

        _burnZero(lower, upper);

        (
            uint128 liq,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = _positionState(lower, upper);

        assertEq(uint256(_activeLiquidity()), 0, "unexpected pool active liquidity");
        assertEq(uint256(liq), uint256(L), "unexpected position liquidity");
        _assertHasCrystallizedFeeState(
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128,
            tokensOwed0,
            tokensOwed1,
            "expected previously earned fee entitlement to remain recoverable below range"
        );
    }

    // ------------------------------------------------------------
    // 3. Above range: burn(0) should not destroy previously earned entitlement
    // ------------------------------------------------------------

    function test_aboveRange_burnZero_preservesPreviouslyEarnedEntitlement() public {
        int24 lower = -60;
        int24 upper = 60;

        _mint(lower, upper, L);

        _swapLeftToTick(-30);
        _swapRightToTick(60);

        _burnZero(lower, upper);

        (
            uint128 liq,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = _positionState(lower, upper);

        assertEq(uint256(_activeLiquidity()), 0, "unexpected pool active liquidity");
        assertEq(uint256(liq), uint256(L), "unexpected position liquidity");
        _assertHasCrystallizedFeeState(
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128,
            tokensOwed0,
            tokensOwed1,
            "expected previously earned fee entitlement to remain recoverable above range"
        );
    }

    // ------------------------------------------------------------
    // 4. Lower-boundary exact-hit vs just-inside path should both crystallize
    // ------------------------------------------------------------

    function test_exactLowerBoundary_vsJustInside_crystallizationRemainsSensible() public {
        int24 lower = -60;
        int24 upper = 60;

        _mint(lower, upper, L);
        _swapLeftToTick(-59);
        _burnZero(lower, upper);

        (
            ,
            uint256 feeGrowthInside0A,
            uint256 feeGrowthInside1A,
            uint128 tokensOwed0A,
            uint128 tokensOwed1A
        ) = _positionState(lower, upper);

        _resetSingleRange(lower, upper, L);
        _burnZero(lower, upper);

        _swapLeftToTick(-60);
        _burnZero(lower, upper);

        (
            ,
            uint256 feeGrowthInside0B,
            uint256 feeGrowthInside1B,
            uint128 tokensOwed0B,
            uint128 tokensOwed1B
        ) = _positionState(lower, upper);

        _assertHasCrystallizedFeeState(
            feeGrowthInside0A,
            feeGrowthInside1A,
            tokensOwed0A,
            tokensOwed1A,
            "just-inside lower-boundary path should show crystallized state"
        );
        _assertHasCrystallizedFeeState(
            feeGrowthInside0B,
            feeGrowthInside1B,
            tokensOwed0B,
            tokensOwed1B,
            "exact-lower-boundary path should show crystallized state"
        );

    }

    // ------------------------------------------------------------
    // 5. Upper-boundary exact-hit vs just-inside path should both crystallize
    // ------------------------------------------------------------

    function test_exactUpperBoundary_vsJustInside_crystallizationRemainsSensible() public {
        int24 lower = -60;
        int24 upper = 60;

        _mint(lower, upper, L);
        _swapRightToTick(59);
        _burnZero(lower, upper);


        (
            ,
            uint256 feeGrowthInside0A,
            uint256 feeGrowthInside1A,
            uint128 tokensOwed0A,
            uint128 tokensOwed1A
        ) = _positionState(lower, upper);

        _resetSingleRange(lower, upper, L);

        // path B: exact-hit upper boundary from inside by moving right
        _swapRightToTick(60);
        _burnZero(lower, upper);

        (
            ,
            uint256 feeGrowthInside0B,
            uint256 feeGrowthInside1B,
            uint128 tokensOwed0B,
            uint128 tokensOwed1B
        ) = _positionState(lower, upper);

        _assertHasCrystallizedFeeState(
            feeGrowthInside0A,
            feeGrowthInside1A,
            tokensOwed0A,
            tokensOwed1A,
            "just-inside upper-boundary path should show crystallized state"
        );
        _assertHasCrystallizedFeeState(
            feeGrowthInside0B,
            feeGrowthInside1B,
            tokensOwed0B,
            tokensOwed1B,
            "exact-upper-boundary path should show crystallized state"
        );
    }
}
