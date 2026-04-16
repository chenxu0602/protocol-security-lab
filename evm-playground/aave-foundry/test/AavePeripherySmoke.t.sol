// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {IRewardsController} from "@aave/periphery-v3/contracts/rewards/interfaces/IRewardsController.sol";
import {RewardsDataTypes} from "@aave/periphery-v3/contracts/rewards/libraries/RewardsDataTypes.sol";

contract AavePeripherySmokeTest {
    function test_peripheryImportsCompile() external pure {
        IRewardsController controller;
        RewardsDataTypes.UserAssetBalance[] memory balances;

        require(address(controller) == address(0), "unexpected controller");
        require(balances.length == 0, "unexpected balances");
    }
}
