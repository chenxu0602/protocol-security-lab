// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import {TestUniswapV3Callee} from "@uniswap/v3-core/contracts/test/TestUniswapV3Callee.sol";

contract DeployLocalUniV3 is Script {
    uint24 internal constant FEE = 3000;
    int24 internal constant INITIAL_TICK = 55;
    int24 internal constant SEED_LOWER_TICK = 0;
    int24 internal constant SEED_UPPER_TICK = 60;
    uint128 internal constant SEED_LIQUIDITY = 2e18;
    uint128 internal constant WIDE_LIQUIDITY = 2e18;
    uint16 internal constant OBSERVATION_CARDINALITY_NEXT = 16;

    function run() external {
        vm.startBroadcast();

        UniswapV3Factory factory = new UniswapV3Factory();
        TestUniswapV3Callee callee = new TestUniswapV3Callee();
        TestERC20 token0 = new TestERC20(0);
        TestERC20 token1 = new TestERC20(0);

        address poolAddr = factory.createPool(address(token0), address(token1), FEE);
        IUniswapV3Pool(poolAddr).initialize(TickMath.getSqrtRatioAtTick(INITIAL_TICK));
        IUniswapV3Pool(poolAddr).increaseObservationCardinalityNext(OBSERVATION_CARDINALITY_NEXT);

        token0.mint(msg.sender, 1e30);
        token1.mint(msg.sender, 1e30);

        token0.approve(address(callee), type(uint256).max);
        token1.approve(address(callee), type(uint256).max);

        callee.mint(poolAddr, msg.sender, -600, 600, WIDE_LIQUIDITY);
        callee.mint(poolAddr, msg.sender, SEED_LOWER_TICK, SEED_UPPER_TICK, SEED_LIQUIDITY);

        vm.stopBroadcast();

        console2.log("local deployment file:", "cache/local_univ3_deployment.json");
        console2.log("pool:", poolAddr);
        console2.log("token0:", address(token0));
        console2.log("token1:", address(token1));
        console2.log("callee:", address(callee));

        string memory obj = "deployment";
        vm.serializeAddress(obj, "pool", poolAddr);
        vm.serializeAddress(obj, "token0", address(token0));
        vm.serializeAddress(obj, "token1", address(token1));
        vm.serializeAddress(obj, "callee", address(callee));
        vm.serializeUint(obj, "fee", uint256(FEE));
        vm.serializeUint(obj, "observationCardinalityNext", uint256(OBSERVATION_CARDINALITY_NEXT));
        vm.serializeInt(obj, "initialTick", INITIAL_TICK);
        vm.serializeInt(obj, "seedLowerTick", SEED_LOWER_TICK);
        string memory output = vm.serializeInt(obj, "seedUpperTick", SEED_UPPER_TICK);
        vm.writeJson(output, "cache/local_univ3_deployment.json");
    }
}
