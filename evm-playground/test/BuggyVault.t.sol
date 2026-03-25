// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BuggyVault.sol";

contract BuggyVaultTest is Test {
    BuggyVault vault;

    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        vault = new BuggyVault();
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function testDepositUpdatesBalance() public {
        vm.prank(user1);
        vault.deposit{value: 1 ether}();

        assertEq(vault.balanceOf(user1), 1 ether);
        assertEq(vault.totalAssets(), 1 ether);
    }

    function testWithdrawShouldReduceTotalAssets() public {
        vm.startPrank(user1);
        vault.deposit{value: 2 ether}();
        vault.withdraw(1 ether);
        vm.stopPrank();

        assertEq(vault.balanceOf(user1), 1 ether);
        assertEq(vault.totalAssets(), 1 ether); // should fail
    }

    function testMultipleUsersAccountingStaysConsistent() public {
        vm.prank(user1);
        vault.deposit{value: 3 ether}();

        vm.prank(user2);
        vault.deposit{value: 5 ether}();

        vm.prank(user1);
        vault.withdraw(1 ether);

        uint256 expectedUser1 = 2 ether;
        uint256 expectedUser2 = 5 ether;
        uint256 expectedTotal = expectedUser1 + expectedUser2;

        assertEq(vault.balanceOf(user1), expectedUser1);
        assertEq(vault.balanceOf(user2), expectedUser2);
        assertEq(vault.totalAssets(), expectedTotal); // should fail
    }
}