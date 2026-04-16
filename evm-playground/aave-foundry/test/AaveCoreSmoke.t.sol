// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

contract AaveCoreSmokeTest {
    function test_coreImportsCompile() external pure {
        IPool pool;
        DataTypes.InterestRateMode mode = DataTypes.InterestRateMode.NONE;

        require(address(pool) == address(0), "unexpected pool");
        require(uint256(mode) == 0, "unexpected interest rate mode");
    }
}
