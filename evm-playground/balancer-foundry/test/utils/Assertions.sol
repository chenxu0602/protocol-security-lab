// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "./Vm.sol";

abstract contract Assertions {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertFalse(bool condition, string memory message) internal pure {
        require(!condition, message);
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(bytes32 left, bytes32 right, string memory message) internal pure {
        require(left == right, message);
    }
}
