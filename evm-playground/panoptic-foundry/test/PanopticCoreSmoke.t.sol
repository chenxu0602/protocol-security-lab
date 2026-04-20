// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { Test } from 'forge-std/Test.sol';

import { Constants } from 'panoptic-v2-core/contracts/libraries/Constants.sol';

contract PanopticCoreSmokeTest is Test {
    function test_panopticImportPathCompiles() external pure {
        assertEq(Constants.FP96, 0x1000000000000000000000000);
    }
}
