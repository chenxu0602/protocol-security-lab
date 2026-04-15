// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import {TestUniswapV3Callee} from "@uniswap/v3-core/contracts/test/TestUniswapV3Callee.sol";

import {MockUniswapV3Factory} from "src/mocks/MockUniswapV3Factory.sol";

/// @notice Active-liquidity crossing regression tests.
/// @dev This file checks that crossing initialized ticks changes
/// `pool.liquidity()` by the expected net amount, and that a round-trip cross
/// still leaves positions settleable.
contract PoolCrossingDirectionTest is Test {
    uint24 internal constant FEE = 3000;
    int24  internal constant SPACING = 60;

    uint128 internal constant L0 = 1e18;
    uint128 internal constant L1 = 2e18;

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
    // position / fixture composition helpers
    // ------------------------------------------------------------

    function _positionKey(int24 lower, int24 upper) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), lower, upper));
    }

    function _assertCurrentState(
        uint160 expectedSqrtPriceX96,
        int24 expectedTick,
        uint128 expectedActiveLiquidity
    ) internal view {
        (uint160 sqrtPriceX96, int24 tick) = _slot0();
        assertEq(uint256(sqrtPriceX96), uint256(expectedSqrtPriceX96), "unexpected current sqrtPrice");
        assertEq(int256(tick), int256(expectedTick), "unexpected current tick");
        assertEq(uint256(_activeLiquidity()), uint256(expectedActiveLiquidity), "unexpected pool active liquidity");
    }

    function _seedOverlappingRanges() internal {
        _mint(-120, 60, L0);
        _mint(0, 120, L1);
    }

    // ------------------------------------------------------------
    // 1. Single range: exact-hit upper tick should deactivate all liquidity
    // ------------------------------------------------------------

    function test_exactHitUpper_singlePosition_liquidityDropsToZero() public {
        _mint(-60, 60, L0);

        _assertCurrentState(_sqrtAt(0), 0, L0);

        _swapRightToTick(60);
        _assertCurrentState(_sqrtAt(60), 60, 0);
    }

    // ------------------------------------------------------------
    // 2. Two overlapping ranges: cross right through one initialized tick
    // posA = [-120, 60] with L0
    // posB = [0, 120]   with L1
    //
    // start at tick 0:
    // - A active
    // - B active
    // total = L0 + L1
    //
    // cross right over tick 60:
    // - A deactivates
    // - B stays active
    // total = L1
    // ------------------------------------------------------------

    function test_crossRight_overlappingPositions_activeLiquidityDropsByExpectedNet() public {
        _seedOverlappingRanges();

        _assertCurrentState(_sqrtAt(0), 0, L0 + L1);

        uint256 feeGrowth0Before = pool.feeGrowthGlobal0X128();

        _swapRightToTick(119);

        (uint160 sqrtPriceX96, int24 tick) = _slot0();
        assertEq(uint256(sqrtPriceX96), uint256(_sqrtAt(119)), "unexpected final sqrtPrice after rightward cross");
        assertEq(int256(tick), int256(119), "unexpected final tick after rightward cross");

        assertEq(uint256(_activeLiquidity()), uint256(L1), "unexpected pool active liquidity after rightward cross");

        assertGt(pool.feeGrowthGlobal1X128(), 0, "expected some fee growth on input side");
        assertEq(pool.feeGrowthGlobal0X128(), feeGrowth0Before, "unexpected fee growth on token0 side");
    }

    // ------------------------------------------------------------
    // 3. Two overlapping ranges: cross right, then exact-hit back left
    //
    // crossing left over tick 60 should re-activate posA
    // so liquidity goes from L1 back to L0 + L1
    //
    // Note: exact-hitting tick 60 from the right leaves sqrtPrice at sqrt(60)
    // while current tick becomes 59.
    // ------------------------------------------------------------
    function test_crossRightThenLeft_overlappingPositions_liquidityRestoresExactly() public {
        _seedOverlappingRanges();

        _assertCurrentState(_sqrtAt(0), 0, L0 + L1);

        _swapRightToTick(119);
        _assertCurrentState(_sqrtAt(119), 119, L1);

        uint256 feeGrowth1BeforeLeftSwap = pool.feeGrowthGlobal1X128();

        _swapLeftToTick(60);

        (uint160 sqrtPriceX96, int24 tick) = _slot0();
        assertEq(uint256(sqrtPriceX96), uint256(_sqrtAt(60)), "unexpected final sqrtPrice after leftward exact-hit");

        assertEq(int256(tick), int256(59), "unexpected final tick after leftward exact-hit");
        assertEq(uint256(_activeLiquidity()), uint256(L0 + L1), "unexpected pool active liquidity after leftward reactivation");

        assertGt(pool.feeGrowthGlobal0X128(), 0, "expected token0-side fee growth on leftward swap");
        assertGe(pool.feeGrowthGlobal1X128(), feeGrowth1BeforeLeftSwap, "fee growth should not go backwards");
    }

    // ------------------------------------------------------------
    // 4. Exact-hit vs cross-through should produce the same net active-liquidity change
    // ------------------------------------------------------------

    function test_exactHitVsCrossThrough_sameBoundarySameNetLiquidityChange() public {
        _seedOverlappingRanges();

        _swapRightToTick(60);

        (uint160 sqrtA, int24 tickA) = _slot0();
        uint128 liqA = _activeLiquidity();

        assertEq(uint256(sqrtA), uint256(_sqrtAt(60)), "unexpected exact-hit sqrtPrice");
        assertEq(int256(tickA), int256(60), "unexpected exact-hit tick");
        assertEq(uint256(liqA), uint256(L1), "unexpected pool active liquidity on exact-hit");

        setUp();
        _seedOverlappingRanges();

        _swapRightToTick(119);
        (uint160 sqrtB, int24 tickB) = _slot0();
        uint128 liqB = _activeLiquidity();

        assertEq(uint256(sqrtB), uint256(_sqrtAt(119)), "unexpected cross-through sqrtPrice");
        assertEq(int256(tickB), int256(119), "unexpected cross-through tick");
        assertEq(uint256(liqB), uint256(L1), "unexpected pool active liquidity after cross-through");

    }

    // ------------------------------------------------------------
    // 5. Round-trip crossing should not break later fee crystallization
    // ------------------------------------------------------------

    function test_roundTrip_thenBurnZero_positionsCanStillCrystallizeFees() public {
        _seedOverlappingRanges();

        _swapRightToTick(120);
        _swapLeftToTick(60);

        pool.burn(-120, 60, 0);
        pool.burn(0, 120, 0);

        (
            uint128 liq0,
            uint256 feeGrowthInside0Last0,
            uint256 feeGrowthInside1Last0,
            uint128 tokensOwed0A,
            uint128 tokensOwed1A
        ) = pool.positions(_positionKey(-120, 60));

        (
            uint128 liq1,
            uint256 feeGrowthInside0Last1,
            uint256 feeGrowthInside1Last1,
            uint128 tokensOwed0B,
            uint128 tokensOwed1B
        ) = pool.positions(_positionKey(0, 120));

        assertEq(uint256(liq0), uint256(L0), "unexpected position liquidity for left range");
        assertEq(uint256(liq1), uint256(L1), "unexpected position liquidity for right range");

        assertTrue(
                feeGrowthInside0Last0 > 0 || feeGrowthInside1Last0 > 0 || tokensOwed0A > 0 || tokensOwed1A > 0,
                "posA should reflect some crystallized state"
        );
        assertTrue(
                feeGrowthInside0Last1 > 0 || feeGrowthInside1Last1 > 0 || tokensOwed0B > 0 || tokensOwed1B > 0,
                "posB should reflect some crystallized state"
        );
    }


    function _boundedLiquidity(uint256 seed) internal pure returns (uint128) {
        return uint128(1e18 + (seed % 2e18));
    }

    function _assertHasCrystallizedState(
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

    function _seedTwoRangeFixture(uint128 leftLiquidity, uint128 rightLiquidity) internal {
        _mint(-120, 60, leftLiquidity);
        _mint(0, 120, rightLiquidity);
    }

    function _seedThreeRangeFixture(uint128 leftLiquidity, uint128 middleLiquidity, uint128 rightLiquidity) internal {
        _mint(-120, 60, leftLiquidity);
        _mint(0, 120, middleLiquidity);
        _mint(60, 180, rightLiquidity);
    }


    function testFuzz_crossRight_activeLiquidityMatchesExpectedNet_twoRanges(
        uint256 leftSeed,
        uint256 rightSeed
    ) public {
        uint128 leftLiquidity = _boundedLiquidity(leftSeed);
        uint128 rightLiquidity = _boundedLiquidity(rightSeed);

        _seedTwoRangeFixture(leftLiquidity, rightLiquidity);

        assertEq(
            uint256(_activeLiquidity()),
            uint256(leftLiquidity) + uint256(rightLiquidity),
            "unexpected initial active liquidity"
        );

        _swapRightToTick(119);

        (uint160 sqrtPriceX96, int24 tick) = _slot0();

        assertEq(uint256(sqrtPriceX96), uint256(_sqrtAt(119)), "unexpected final sqrtPrice after rightward cross");
        assertEq(int256(tick), int256(119), "unexpected final tick after rightward cross");
        assertEq(uint256(_activeLiquidity()), uint256(rightLiquidity), "unexpected active liquidity after crossing tick 60");
    }

    function testFuzz_crossRightThenLeft_roundTrip_preservesLiquidityAndCrystallization_threeRanges(
        uint256 leftSeed,
        uint256 middleSeed,
        uint256 rightSeed
    ) public {
        uint128 leftLiquidity = _boundedLiquidity(leftSeed);
        uint128 middleLiquidity = _boundedLiquidity(middleSeed);
        uint128 rightLiquidity = _boundedLiquidity(rightSeed);

        _seedThreeRangeFixture(leftLiquidity, middleLiquidity, rightLiquidity);

        assertEq(
            uint256(_activeLiquidity()),
            uint256(leftLiquidity) + uint256(middleLiquidity),
            "unexpected initial active liquidity"
        );

        _swapRightToTick(179);
        (uint160 sqrtPriceAfterRight, int24 tickAfterRight) = _slot0();
        assertEq(uint256(sqrtPriceAfterRight), uint256(_sqrtAt(179)), "unexpected sqrtPrice after crossing two ticks right");
        assertEq(int256(tickAfterRight), int256(179), "unexpected tick after crossing two ticks right");
        assertEq(uint256(_activeLiquidity()), uint256(rightLiquidity), "unexpected active liquidity after rightward crossings");

        _swapLeftToTick(60);

        (uint160 sqrtPriceAfterLeft, int24 tickAfterLeft) = _slot0();
        assertEq(uint256(sqrtPriceAfterLeft), uint256(_sqrtAt(60)), "unexpected sqrtPrice after leftward exact-hit");
        assertEq(int256(tickAfterLeft), int256(59), "unexpected tick after leftward exact-hit");
        assertEq(
            uint256(_activeLiquidity()),
            uint256(leftLiquidity) + uint256(middleLiquidity),
            "unexpected active liquidity after round-trip reactivation"
        );

        pool.burn(-120, 60, 0);
        pool.burn(0, 120, 0);
        pool.burn(60, 180, 0);

        assertEq(
            uint256(_positionLiquidity(-120, 60)),
            uint256(leftLiquidity),
            "unexpected position liquidity for left range"
        );
        assertEq(
            uint256(_positionLiquidity(0, 120)),
            uint256(middleLiquidity),
            "unexpected position liquidity for middle range"
        );
        assertEq(
            uint256(_positionLiquidity(60, 180)),
            uint256(rightLiquidity),
            "unexpected position liquidity for right range"
        );

        _assertPositionHasCrystallizedState(-120, 60, "left range should remain crystallizable after round-trip");
        _assertPositionHasCrystallizedState(0, 120, "middle range should remain crystallizable after round-trip");
        _assertPositionHasCrystallizedState(60, 180, "right range should remain crystallizable after round-trip");
    }


    function _assertPositionHasCrystallizedState(int24 lower, int24 upper, string memory message) internal view {
        (
            ,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = pool.positions(_positionKey(lower, upper));

        assertTrue(
            feeGrowthInside0LastX128 > 0 || feeGrowthInside1LastX128 > 0 || tokensOwed0 > 0 || tokensOwed1 > 0,
            message
        );
    }

    function _positionLiquidity(int24 lower, int24 upper) internal view returns (uint128 liquidity_) {
        (liquidity_, , , , ) = pool.positions(_positionKey(lower, upper));
    }
}
