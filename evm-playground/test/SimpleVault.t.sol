// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SimpleVault.sol";

contract SimpleVaultTest is Test {
    SimpleVault vault;

    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        vault = new SimpleVault();
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function testDepositUpdatesBalance() public {
        vm.prank(user1);
        vault.deposit{value: 1 ether}();

        assertEq(vault.balanceOf(user1), 1 ether);
        assertEq(vault.totalAssets(), 1 ether);
    }

    function testWithdrawReducesBalance() public {
        vm.startPrank(user1);
        vault.deposit{value: 2 ether}();
        vault.withdraw(1 ether);
        vm.stopPrank();

        assertEq(vault.balanceOf(user1), 1 ether);
        assertEq(vault.totalAssets(), 1 ether);
    }

    function testCannotWithdrawTooMuch() public {
        vm.startPrank(user1);
        vault.deposit{value: 1 ether}();
        vm.expectRevert("insufficient balance");
        vault.withdraw(2 ether);
        vm.stopPrank();
    }
}
