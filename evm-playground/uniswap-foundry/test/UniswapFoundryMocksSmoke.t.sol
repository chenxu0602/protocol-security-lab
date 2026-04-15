// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { TestERC20 } from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import { MockMath } from "src/mocks/MockMath.sol";
import { MockOracle } from "src/mocks/MockOracle.sol";
import { MockPosition } from "src/mocks/MockPosition.sol";
import { MockTick } from "src/mocks/MockTick.sol";
import { MockTickMath } from "src/mocks/MockTickMath.sol";
import { MockUniswapV3Factory } from "src/mocks/MockUniswapV3Factory.sol";
import { MockUniswapV3PoolDeployer } from "src/mocks/MockUniswapV3PoolDeployer.sol";

contract UniswapFoundryMocksSmokeTest {
    function test_poolHelpersDeployRealPools() external {
        MockUniswapV3Factory factoryHelper = new MockUniswapV3Factory();
        (,, TestERC20 token0, TestERC20 token1) =
            factoryHelper.createFactoryAndPool(3000, TickMath.getSqrtRatioAtTick(0));

        MockUniswapV3PoolDeployer deployer = new MockUniswapV3PoolDeployer();
        address pool =
            deployer.deployAndInitializePool(address(this), address(token0), address(token1), 3000, 60, 79228162514264337593543950336);

        require(IUniswapV3Pool(pool).factory() == address(this), "unexpected factory");
        require(IUniswapV3Pool(pool).token0() == address(token0), "unexpected token0");
        require(IUniswapV3Pool(pool).token1() == address(token1), "unexpected token1");
        require(IUniswapV3Pool(pool).tickSpacing() == 60, "unexpected spacing");
    }

    function test_libraryHarnessesExposeCoreMath() external {
        MockTickMath tickMath = new MockTickMath();
        MockMath math = new MockMath();

        uint160 sqrtAtZero = tickMath.getSqrtRatioAtTick(0);
        require(sqrtAtZero == 79228162514264337593543950336, "unexpected sqrt ratio");
        require(tickMath.getTickAtSqrtRatio(sqrtAtZero) == 0, "unexpected tick round trip");
        require(math.addDelta(100, -40) == 60, "unexpected liquidity delta");

        (uint160 sqrtNext, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            math.computeSwapStep(sqrtAtZero, TickMath.getSqrtRatioAtTick(-60), 1e18, 1e15, 3000);

        require(sqrtNext > 0, "sqrt step");
        require(amountIn > 0, "amount in");
        require(amountOut > 0, "amount out");
        require(feeAmount > 0, "fee");
    }

    function test_statefulHarnessesTrackTickPositionAndOracle() external {
        MockTick tickHarness = new MockTick();
        MockPosition positionHarness = new MockPosition();
        MockOracle oracleHarness = new MockOracle();

        bool flipped = tickHarness.updateTick(60, 0, 100, 11, 17, 23, 29, 31, false, type(uint128).max);
        require(flipped, "tick should flip");

        (uint128 liquidityGross, int128 liquidityNet,,,,,, bool initialized) = tickHarness.getTickInfo(60);
        require(liquidityGross == 100, "unexpected liquidity gross");
        require(liquidityNet == 100, "unexpected liquidity net");
        require(initialized, "tick should be initialized");

        positionHarness.updatePosition(address(this), -60, 60, 100, 0, 0);
        positionHarness.updatePosition(address(this), -60, 60, 0, uint256(1) << 128, uint256(2) << 128);

        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1) =
            positionHarness.getPosition(address(this), -60, 60);
        require(liquidity == 100, "unexpected position liquidity");
        require(feeGrowthInside0LastX128 == uint256(1) << 128, "unexpected fee growth 0");
        require(feeGrowthInside1LastX128 == uint256(2) << 128, "unexpected fee growth 1");
        require(tokensOwed0 == 100, "unexpected owed0");
        require(tokensOwed1 == 200, "unexpected owed1");

        oracleHarness.initialize(100);
        oracleHarness.grow(2);
        oracleHarness.write(110, 5, 100);

        (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = oracleHarness.observeSingle(110, 0, 5, 100);
        require(tickCumulative == 50, "unexpected tick cumulative");
        require(secondsPerLiquidityCumulativeX128 > 0, "unexpected seconds per liquidity");
    }
}
