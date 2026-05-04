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
    uint24 internal constant DEFAULT_FEE = 3000;
    int24 internal constant DEFAULT_INITIAL_TICK = 55;

    int24 internal constant DEFAULT_WIDE_LOWER_TICK = -600;
    int24 internal constant DEFAULT_WIDE_UPPER_TICK = 600;
    uint128 internal constant DEFAULT_WIDE_LIQUIDITY = 2e18;

    int24 internal constant DEFAULT_SEED_LOWER_TICK = 0;
    int24 internal constant DEFAULT_SEED_UPPER_TICK = 60;
    uint128 internal constant DEFAULT_SEED_LIQUIDITY = 2e18;

    uint16 internal constant DEFAULT_OBSERVATION_CARDINALITY_NEXT = 16;

    string internal constant DEFAULT_DEPLOYMENT_JSON_PATH =
        "cache/local_univ3_deployment.json";

    struct DeployConfig {
        uint24 fee;
        int24 initialTick;
        int24 wideLowerTick;
        int24 wideUpperTick;
        uint128 wideLiquidity;
        int24 seedLowerTick;
        int24 seedUpperTick;
        uint128 seedLiquidity;
        uint16 observationCardinalityNext;
        string deploymentJsonPath;
    }

    function run() external {
        DeployConfig memory cfg = _loadConfig();

        vm.startBroadcast();

        UniswapV3Factory factory = new UniswapV3Factory();
        TestUniswapV3Callee callee = new TestUniswapV3Callee();
        TestERC20 token0 = new TestERC20(0);
        TestERC20 token1 = new TestERC20(0);

        address poolAddr =
            factory.createPool(address(token0), address(token1), cfg.fee);

        IUniswapV3Pool(poolAddr).initialize(
            TickMath.getSqrtRatioAtTick(cfg.initialTick)
        );
        IUniswapV3Pool(poolAddr).increaseObservationCardinalityNext(
            cfg.observationCardinalityNext
        );

        token0.mint(msg.sender, 1e30);
        token1.mint(msg.sender, 1e30);

        token0.approve(address(callee), type(uint256).max);
        token1.approve(address(callee), type(uint256).max);

        callee.mint(
            poolAddr,
            msg.sender,
            cfg.wideLowerTick,
            cfg.wideUpperTick,
            cfg.wideLiquidity
        );
        callee.mint(
            poolAddr,
            msg.sender,
            cfg.seedLowerTick,
            cfg.seedUpperTick,
            cfg.seedLiquidity
        );

        vm.stopBroadcast();

        console2.log("local deployment file:", cfg.deploymentJsonPath);
        console2.log("pool:", poolAddr);
        console2.log("token0:", address(token0));
        console2.log("token1:", address(token1));
        console2.log("callee:", address(callee));
        console2.log("factory:", address(factory));

        _writeDeploymentJson(
            cfg,
            address(factory),
            poolAddr,
            address(token0),
            address(token1),
            address(callee)
        );
    }

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        cfg.fee = uint24(vm.envOr("FEE", uint256(DEFAULT_FEE)));
        cfg.initialTick = int24(vm.envOr("INITIAL_TICK", int256(DEFAULT_INITIAL_TICK)));

        cfg.wideLowerTick =
            int24(vm.envOr("WIDE_LOWER_TICK", int256(DEFAULT_WIDE_LOWER_TICK)));
        cfg.wideUpperTick =
            int24(vm.envOr("WIDE_UPPER_TICK", int256(DEFAULT_WIDE_UPPER_TICK)));
        cfg.wideLiquidity =
            uint128(vm.envOr("WIDE_LIQUIDITY", uint256(DEFAULT_WIDE_LIQUIDITY)));

        cfg.seedLowerTick =
            int24(vm.envOr("SEED_LOWER_TICK", int256(DEFAULT_SEED_LOWER_TICK)));
        cfg.seedUpperTick =
            int24(vm.envOr("SEED_UPPER_TICK", int256(DEFAULT_SEED_UPPER_TICK)));
        cfg.seedLiquidity =
            uint128(vm.envOr("SEED_LIQUIDITY", uint256(DEFAULT_SEED_LIQUIDITY)));

        cfg.observationCardinalityNext = uint16(
            vm.envOr(
                "OBSERVATION_CARDINALITY_NEXT",
                uint256(DEFAULT_OBSERVATION_CARDINALITY_NEXT)
            )
        );

        cfg.deploymentJsonPath =
            vm.envOr("DEPLOYMENT_JSON_PATH", DEFAULT_DEPLOYMENT_JSON_PATH);
    }

    function _writeDeploymentJson(
        DeployConfig memory cfg,
        address factory,
        address pool,
        address token0,
        address token1,
        address callee
    ) internal {
        string memory obj = "deployment";

        vm.serializeAddress(obj, "pool", pool);
        vm.serializeAddress(obj, "token0", token0);
        vm.serializeAddress(obj, "token1", token1);
        vm.serializeAddress(obj, "callee", callee);
        vm.serializeAddress(obj, "factory", factory);

        vm.serializeUint(obj, "fee", uint256(cfg.fee));
        vm.serializeUint(
            obj,
            "observationCardinalityNext",
            uint256(cfg.observationCardinalityNext)
        );

        vm.serializeInt(obj, "initialTick", cfg.initialTick);

        vm.serializeInt(obj, "wideLowerTick", cfg.wideLowerTick);
        vm.serializeInt(obj, "wideUpperTick", cfg.wideUpperTick);
        vm.serializeUint(obj, "wideLiquidity", uint256(cfg.wideLiquidity));

        vm.serializeInt(obj, "seedLowerTick", cfg.seedLowerTick);
        vm.serializeInt(obj, "seedUpperTick", cfg.seedUpperTick);
        string memory output =
            vm.serializeUint(obj, "seedLiquidity", uint256(cfg.seedLiquidity));

        vm.writeJson(output, cfg.deploymentJsonPath);
    }
}
