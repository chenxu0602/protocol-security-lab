// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;
pragma abicoder v2;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/console2.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v3-core/contracts/test/TestERC20.sol";
import {TestUniswapV3Callee} from "@uniswap/v3-core/contracts/test/TestUniswapV3Callee.sol";

contract DriveUniV3Scenario is Script {
    using stdJson for string;

    string internal constant DEFAULT_DEPLOYMENT_FILE = "/cache/local_univ3_deployment.json";

    function run() external {
        string memory deploymentPath = _deploymentPath();
        string memory mode = vm.envOr("MODE", string("boundary"));
        uint256 cycles = vm.envOr("CYCLES", uint256(4));

        string memory json = vm.readFile(deploymentPath);
        address pool = json.readAddress(".pool");
        address callee = json.readAddress(".callee");
        address token0 = json.readAddress(".token0");
        address token1 = json.readAddress(".token1");

        (int24 upperTick, int24 lowerTick) = _scenarioBounds(mode);

        vm.startBroadcast();

        TestERC20(token0).approve(callee, type(uint256).max);
        TestERC20(token1).approve(callee, type(uint256).max);

        for (uint256 i = 0; i < cycles; i++) {
            TestUniswapV3Callee(callee).swapToHigherSqrtPrice(
                pool, TickMath.getSqrtRatioAtTick(upperTick), msg.sender
            );
            TestUniswapV3Callee(callee).swapToLowerSqrtPrice(
                pool, TickMath.getSqrtRatioAtTick(lowerTick), msg.sender
            );
        }

        vm.stopBroadcast();

        (, int24 currentTick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext,,) =
            IUniswapV3Pool(pool).slot0();

        console2.log("deployment file:", deploymentPath);
        console2.log("mode:", mode);
        console2.log("cycles:", cycles);
        console2.log("pool:", pool);
        console2.log("end tick:", currentTick);
        console2.log("observation index/cardinality/cardinalityNext:");
        console2.logUint(uint256(observationIndex));
        console2.logUint(uint256(observationCardinality));
        console2.logUint(uint256(observationCardinalityNext));
    }

    function _deploymentPath() internal view returns (string memory) {
        string memory root = vm.projectRoot();
        string memory deploymentFile = vm.envOr("DEPLOYMENT_FILE", string(""));
        if (bytes(deploymentFile).length == 0) {
            return string(abi.encodePacked(root, DEFAULT_DEPLOYMENT_FILE));
        }
        return deploymentFile;
    }

    function _scenarioBounds(string memory mode) internal pure returns (int24 upperTick, int24 lowerTick) {
        if (_equals(mode, "boundary")) {
            return (59, 54);
        }
        if (_equals(mode, "cross")) {
            return (119, 0);
        }
        revert("unsupported MODE; use boundary or cross");
    }

    function _equals(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
