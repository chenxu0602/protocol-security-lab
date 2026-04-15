// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;
import "forge-std/Test.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import {TestUniswapV3Callee} from "@uniswap/v3-core/contracts/test/TestUniswapV3Callee.sol";

import {MockUniswapV3Factory} from "src/mocks/MockUniswapV3Factory.sol";

/// @notice Step-level fee attribution regression tests.
/// @dev This file checks the core Uniswap v3 accounting rule:
/// each swap step attributes fee growth only to liquidity active during that
/// step, never to liquidity activated after the crossing.
contract StepFeeAttributionTest is Test {
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;

    uint128 internal constant L = 1e18;

    int24 internal constant LEFT_LOWER = -60;
    int24 internal constant LEFT_UPPER = 60;
    int24 internal constant RIGHT_LOWER = 60;
    int24 internal constant RIGHT_UPPER = 120;

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
    // pool action helpers
    // ------------------------------------------------------------

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

    function _burnZero(int24 lower, int24 upper) internal {
        pool.burn(lower, upper, 0);
    }

    // ------------------------------------------------------------
    // position / fixture composition helpers
    // ------------------------------------------------------------

    function _positionKey(int24 lower, int24 upper) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), lower, upper));
    }

    function _positionState(int24 lower, int24 upper)
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
        return pool.positions(_positionKey(lower, upper));
    }

    function _owed(int24 lower, int24 upper) internal view returns (uint128 owed0, uint128 owed1) {
        (, , , owed0, owed1) = _positionState(lower, upper);
    }

    function _seedAdjacentRanges() internal {
        _mint(LEFT_LOWER, LEFT_UPPER, L);
        _mint(RIGHT_LOWER, RIGHT_UPPER, L);
    }

    function _crystallizeBoth() internal {
        _burnZero(LEFT_LOWER, LEFT_UPPER);
        _burnZero(RIGHT_LOWER, RIGHT_UPPER);
    }

    function _resetAdjacentRanges() internal {
        setUp();
        _seedAdjacentRanges();
    }

    // ------------------------------------------------------------
    // deterministic attribution cases
    // ------------------------------------------------------------

    function test_crossingStep_feeBelongsToPreCrossActiveLiquidity() public {
        _seedAdjacentRanges();

        _swapRightToTick(60);
        _crystallizeBoth();

        (, uint128 leftOwed1AtBoundary) = _owed(LEFT_LOWER, LEFT_UPPER);
        (, uint128 rightOwed1AtBoundary) = _owed(RIGHT_LOWER, RIGHT_UPPER);

        assertGt(uint256(leftOwed1AtBoundary), 0, "pre-cross range should earn boundary step fee");
        assertEq(uint256(rightOwed1AtBoundary), 0, "post-cross range should not earn boundary step fee");

        _swapRightToTick(119);
        _crystallizeBoth();

        (, uint128 leftOwed1SplitFinal) = _owed(LEFT_LOWER, LEFT_UPPER);
        (, uint128 rightOwed1SplitFinal) = _owed(RIGHT_LOWER, RIGHT_UPPER);

        assertEq(
            uint256(leftOwed1SplitFinal),
            uint256(leftOwed1AtBoundary),
            "left range should stop earning once tick 60 is crossed"
        );

        assertGt(uint256(rightOwed1SplitFinal), 0, "right range should earn only post-cross step fees");

        _resetAdjacentRanges();

        _swapRightToTick(119);
        _crystallizeBoth();

        (, uint128 leftOwed1Combined) = _owed(LEFT_LOWER, LEFT_UPPER);
        (, uint128 rightOwed1Combined) = _owed(RIGHT_LOWER, RIGHT_UPPER);

        assertEq(
            uint256(leftOwed1Combined),
            uint256(leftOwed1AtBoundary),
            "crossing step fee leaked away from pre-cross active liquidity"
        );
        assertEq(
            uint256(rightOwed1Combined),
            uint256(rightOwed1SplitFinal),
            "right range should only receive post-cross fees"
        );
    }

    function test_exactHitInitializedTick_feeDoesNotLeakToNextRange() public {
        _seedAdjacentRanges();
        _swapRightToTick(60);
        _crystallizeBoth();

        (, uint128 leftOwed1Exact) = _owed(LEFT_LOWER, LEFT_UPPER);
        (, uint128 rightOwed1Exact) = _owed(RIGHT_LOWER, RIGHT_UPPER);

        assertGt(uint256(leftOwed1Exact), 0, "active range should earn exact-hit step fee");
        assertEq(uint256(rightOwed1Exact), 0, "next range must not earn exact-hit boundary fee");

        _resetAdjacentRanges();

        _swapRightToTick(119);
        _crystallizeBoth();

        (, uint128 leftOwed1Cross) = _owed(LEFT_LOWER, LEFT_UPPER);
        (, uint128 rightOwed1Cross) = _owed(RIGHT_LOWER, RIGHT_UPPER);


        assertEq(
              uint256(leftOwed1Cross),
              uint256(leftOwed1Exact),
              "crossing past the boundary should not retroactively change exact-hit fee attribution"
        );
        assertGt(uint256(rightOwed1Cross), 0, "next range should only earn after the boundary is crossed");
    }

    function test_reverseDirection_feeAttributionRemainsDirectionConsistent() public {
        _seedAdjacentRanges();
        _swapRightToTick(60);
        _crystallizeBoth();

        (, uint128 leftOwed1AfterFirstRightStep) = _owed(LEFT_LOWER, LEFT_UPPER);
        (, uint128 rightOwed1AfterFirstRightStep) = _owed(RIGHT_LOWER, RIGHT_UPPER);

        assertGt(uint256(leftOwed1AfterFirstRightStep), 0, "left range should earn first rightward step");
        assertEq(uint256(rightOwed1AfterFirstRightStep), 0, "right range should not earn pre-cross rightward fee");

        _swapRightToTick(119);
        _crystallizeBoth();

        (, uint128 leftOwed1SplitFinal) = _owed(LEFT_LOWER, LEFT_UPPER);
        (, uint128 rightOwed1SplitFinal) = _owed(RIGHT_LOWER, RIGHT_UPPER);

        assertEq(
            uint256(leftOwed1SplitFinal),
            uint256(leftOwed1AfterFirstRightStep),
            "left range should not earn after rightward crossing"
        );
        assertGt(uint256(rightOwed1SplitFinal), 0, "right range should earn post-cross rightward fee");

        _swapLeftToTick(60);
        _crystallizeBoth();

        (uint128 leftOwed0AfterFirstLeftStep, ) = _owed(LEFT_LOWER, LEFT_UPPER);
        (uint128 rightOwed0AfterFirstLeftStep, ) = _owed(RIGHT_LOWER, RIGHT_UPPER);    

        assertEq(uint256(leftOwed0AfterFirstLeftStep), 0, "left range should not earn pre-cross leftward fee");
        assertGt(uint256(rightOwed0AfterFirstLeftStep), 0, "right range should earn first leftward step");

        _swapLeftToTick(0);
        _crystallizeBoth();

        (uint128 leftOwed0SplitFinal, uint128 leftOwed1SplitRoundTrip) = _owed(LEFT_LOWER, LEFT_UPPER);
        (uint128 rightOwed0SplitFinal, uint128 rightOwed1SplitRoundTrip) = _owed(RIGHT_LOWER, RIGHT_UPPER);

        assertGt(uint256(leftOwed0SplitFinal), 0, "left range should earn post-cross leftward fee");
        assertEq(
              uint256(rightOwed0SplitFinal),
              uint256(rightOwed0AfterFirstLeftStep),
              "right range should stop earning once crossed back left"
        );

        assertEq(
            uint256(leftOwed1SplitRoundTrip),
            uint256(leftOwed1SplitFinal),
            "rightward token1 attribution should remain stable"
        );
        assertEq(
            uint256(rightOwed1SplitRoundTrip),
            uint256(rightOwed1SplitFinal),
            "rightward token1 attribution should remain stable"
        );

        _resetAdjacentRanges();
        _swapRightToTick(119);
        _swapLeftToTick(0);
        _crystallizeBoth();

        (uint128 leftOwed0Combined, uint128 leftOwed1Combined) = _owed(LEFT_LOWER, LEFT_UPPER);
        (uint128 rightOwed0Combined, uint128 rightOwed1Combined) = _owed(RIGHT_LOWER, RIGHT_UPPER);

        assertEq(uint256(leftOwed0Combined), uint256(leftOwed0SplitFinal), "leftward fee attribution mismatch");
        assertEq(uint256(leftOwed1Combined), uint256(leftOwed1SplitRoundTrip), "rightward fee attribution mismatch");
        assertEq(uint256(rightOwed0Combined), uint256(rightOwed0SplitFinal), "leftward fee attribution mismatch");
        assertEq(uint256(rightOwed1Combined), uint256(rightOwed1SplitRoundTrip), "rightward fee attribution mismatch");
    }
}
