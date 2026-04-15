// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import {TestUniswapV3Callee} from "@uniswap/v3-core/contracts/test/TestUniswapV3Callee.sol";

import {MockUniswapV3Factory} from "src/mocks/MockUniswapV3Factory.sol";

/// @notice Position inventory decomposition regression tests.
/// @dev This file checks the geometric split between token0 and token1 for
/// mint and burn flows across below-range, in-range, above-range, and
/// exact-boundary regimes. The bounded fuzz cases keep the same invariant over
/// small randomized ranges and liquidity sizes.
contract PositionDecompositionTest is Test {
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;
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
    // pool action helpers
    // ------------------------------------------------------------

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = pool.slot0();
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

    function _activeLiquidity() internal view returns (uint128) {
        return pool.liquidity();
    }

    // ------------------------------------------------------------
    // amount / range construction helpers
    // ------------------------------------------------------------

    function _mintCost(int24 lower, int24 upper, uint128 liquidity) internal returns (uint256 spent0, uint256 spent1) {
        uint256 bal0Before = token0.balanceOf(address(this));
        uint256 bal1Before = token1.balanceOf(address(this));

        _mint(lower, upper, liquidity);

        spent0 = bal0Before - token0.balanceOf(address(this));
        spent1 = bal1Before - token1.balanceOf(address(this));
    }

    function _burnLiquidity(int24 lower, int24 upper, uint128 liquidity) internal returns (uint256 amount0, uint256 amount1) {
        return pool.burn(lower, upper, liquidity); 
    }

    function _boundedLiquidity(uint256 seed) internal pure returns (uint128) {
        return uint128(1e18 + (seed % 1e18));
    }

    function _boundedBurnLiquidity(uint128 liquidity, uint256 seed) internal pure returns (uint128) {
        return uint128((uint256(liquidity) / 4) + (seed % (uint256(liquidity) - uint256(liquidity) / 4 + 1)));
    }

    function _belowRange(uint256 offsetSeed, uint256 widthSeed) internal pure returns (int24 lower, int24 upper) {
        int24 offsetSteps = int24(int256(1 + (offsetSeed % 4)));
        int24 widthSteps = int24(int256(1 + (widthSeed % 4)));

        lower = offsetSteps * SPACING;
        upper = lower + widthSteps * SPACING;
    }

    function _aboveRange(uint256 offsetSeed, uint256 widthSeed) internal pure returns (int24 lower, int24 upper) {
        int24 offsetSteps = int24(int256(1 + (offsetSeed % 4)));
        int24 widthSteps = int24(int256(1 + (widthSeed % 4)));

        upper = -offsetSteps * SPACING;
        lower = upper - widthSteps * SPACING;
    }

    function _inRange(uint256 lowerSeed, uint256 upperSeed) internal pure returns (int24 lower, int24 upper) {
        int24 lowerSteps = int24(int256(1 + (lowerSeed % 4)));
        int24 upperSteps = int24(int256(1 + (upperSeed % 4)));

        lower = -lowerSteps * SPACING;
        upper = upperSteps * SPACING;
    }

    function _burnAll(int24 lower, int24 upper, uint128 liquidity) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = pool.burn(lower, upper, liquidity);
    }

    // ------------------------------------------------------------
    // assertion / reset helpers
    // ------------------------------------------------------------

    function _assertCurrentTick(int24 expectedTick) internal view {
        (, int24 tick) = _slot0();
        assertEq(int256(tick), int256(expectedTick), "unexpected current tick");
    }

    function _resetSingleRange(int24 lower, int24 upper, uint128 liquidity) internal {
        setUp();
        _mint(lower, upper, liquidity);
    }

    // ------------------------------------------------------------
    // deterministic decomposition cases
    // ------------------------------------------------------------

    function test_mint_belowRange_requiresOnlyToken0() public {
        int24 lower = 60;
        int24 upper = 120;

        (uint256 spent0, uint256 spent1) = _mintCost(lower, upper, L);

        assertGt(spent0, 0, "below-range mint should spend token0");
        assertEq(spent1, 0, "below-range mint should not spend token1");
        assertEq(uint256(_activeLiquidity()), 0, "below-range mint should leave pool active liquidity at zero");
        _assertCurrentTick(0);
    }

    function test_mint_aboveRange_requiresOnlyToken1() public {
        int24 lower = -120;
        int24 upper = -60;

        (uint256 spent0, uint256 spent1) = _mintCost(lower, upper, L);

        assertEq(spent0, 0, "above-range mint should not spend token0");
        assertGt(spent1, 0, "above-range mint should spend token1");
        assertEq(uint256(_activeLiquidity()), 0, "above-range mint should leave pool active liquidity at zero");
        _assertCurrentTick(0);
    }

    function test_mint_inRange_requiresBothTokens() public {
        int24 lower = -60;
        int24 upper = 60;

        (uint256 spent0, uint256 spent1) = _mintCost(lower, upper, L);

        assertGt(spent0, 0, "in-range mint should spend token0");
        assertGt(spent1, 0, "in-range mint should spend token1");
        assertEq(uint256(_activeLiquidity()), uint256(L), "in-range mint should set pool active liquidity");
        _assertCurrentTick(0);
    }

    function test_burn_regimeMatchesCurrentInventoryDecomposition() public {
        int24 lower = -60;
        int24 upper = 60;

        _mint(lower, upper, L);
        (uint256 inRange0, uint256 inRange1) = _burnAll(lower, upper, L);

        assertGt(inRange0, 0, "in-range burn should return token0");
        assertGt(inRange1, 0, "in-range burn should return token1");

        _resetSingleRange(lower, upper, L);
        _swapLeftToTick(-60);
        _assertCurrentTick(-61);

        (uint256 below0, uint256 below1) = _burnAll(lower, upper, L);

        assertGt(below0, 0, "below-range burn should return token0");
        assertEq(below1, 0, "below-range burn should not return token1");

        _resetSingleRange(lower, upper, L);
        _swapRightToTick(60);
        _assertCurrentTick(60);

        (uint256 above0, uint256 above1) = _burnAll(lower, upper, L);

        assertEq(above0, 0, "above-range burn should not return token0");
        assertGt(above1, 0, "above-range burn should return token1");
    }

    function test_boundary_lower_transition_decomposition() public {
        int24 lower = -60;
        int24 upper = 60;

        _mint(lower, upper, L);
        _swapLeftToTick(-59);

        (uint256 justInside0, uint256 justInside1) = _burnAll(lower, upper, L);

        assertGt(justInside0, 0, "just-inside lower should still return token0");
        assertGt(justInside1, 0, "just-inside lower should still return token1");

        _resetSingleRange(lower, upper, L);
        _swapLeftToTick(-60);
        _assertCurrentTick(-61);

        (uint256 exactBoundary0, uint256 exactBoundary1) = _burnAll(lower, upper, L);

        assertGt(exactBoundary0, 0, "exact-hit lower boundary should return token0");
        assertEq(exactBoundary1, 0, "exact-hit lower boundary should not return token1");
    }

    function test_boundary_upper_transition_decomposition() public {
        int24 lower = -60;
        int24 upper = 60;

        _mint(lower, upper, L);
        _swapRightToTick(59);

        (uint256 justInside0, uint256 justInside1) = _burnAll(lower, upper, L);

        assertGt(justInside0, 0, "just-inside upper should still return token0");
        assertGt(justInside1, 0, "just-inside upper should still return token1");

        _resetSingleRange(lower, upper, L);
        _swapRightToTick(60);
        _assertCurrentTick(60);

        (uint256 exactBoundary0, uint256 exactBoundary1) = _burnAll(lower, upper, L);

        assertEq(exactBoundary0, 0, "exact-hit upper boundary should not return token0");
        assertGt(exactBoundary1, 0, "exact-hit upper boundary should return token1");
    }

    // ------------------------------------------------------------
    // bounded fuzz: decomposition should remain regime-consistent
    // ------------------------------------------------------------

    function testFuzz_belowRange_mintBurn_remainsToken0Only(
        uint256 offsetSeed,
        uint256 widthSeed,
        uint256 liquiditySeed,
        uint256 burnSeed
    ) public {
        (int24 lower, int24 upper) = _belowRange(offsetSeed, widthSeed);
        uint128 liquidity = _boundedLiquidity(liquiditySeed);

        (uint256 spent0, uint256 spent1) = _mintCost(lower, upper, liquidity);

        assertGt(spent0, 0, "below-range mint should spend token0");
        assertEq(spent1, 0, "below-range mint should not spend token1");
        assertEq(uint256(_activeLiquidity()), 0, "below-range mint should not activate pool liquidity");

        uint128 burnLiquidity = _boundedBurnLiquidity(liquidity, burnSeed);
        (uint256 amount0, uint256 amount1) = _burnLiquidity(lower, upper, burnLiquidity);

        assertGt(amount0, 0, "below-range burn should return token0");
        assertEq(amount1, 0, "below-range burn should not return token1");
    }


    function testFuzz_aboveRange_mintBurn_remainsToken0Only(
        uint256 offsetSeed,
        uint256 widthSeed,
        uint256 liquiditySeed,
        uint256 burnSeed
    ) public {
        (int24 lower, int24 upper) = _aboveRange(offsetSeed, widthSeed);
        uint128 liquidity = _boundedLiquidity(liquiditySeed);

        (uint256 spent0, uint256 spent1) = _mintCost(lower, upper, liquidity);

        assertEq(spent0, 0, "above-range mint should not spend token0");
        assertGt(spent1, 0, "above-range mint should spend token1");
        assertEq(uint256(_activeLiquidity()), 0, "above-range mint should not activate pool liquidity");

        uint128 burnLiquidity = _boundedBurnLiquidity(liquidity, burnSeed);
        (uint256 amount0, uint256 amount1) = _burnLiquidity(lower, upper, burnLiquidity);

        assertEq(amount0, 0, "above-range burn should not return token0");
        assertGt(amount1, 0, "above-range burn should return token1");
    }


    function testFuzz_inRange_mintBurn_requiresBothTokens(
        uint256 lowerSeed,
        uint256 upperSeed,
        uint256 liquiditySeed,
        uint256 burnSeed
    ) public {
        (int24 lower, int24 upper) = _inRange(lowerSeed, upperSeed);
        uint128 liquidity = _boundedLiquidity(liquiditySeed);

        (uint256 spent0, uint256 spent1) = _mintCost(lower, upper, liquidity);

        assertGt(spent0, 0, "in-range mint should spend token0");
        assertGt(spent1, 0, "in-range mint should spend token1");
        assertEq(uint256(_activeLiquidity()), uint256(liquidity), "in-range mint should activate full liquidity");

        uint128 burnLiquidity = _boundedBurnLiquidity(liquidity, burnSeed);
        (uint256 amount0, uint256 amount1) = _burnLiquidity(lower, upper, burnLiquidity);

        assertGt(amount0, 0, "in-range burn should return token0");
        assertGt(amount1, 0, "in-range burn should return token1");
    }
}
