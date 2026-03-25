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

    function testZeroDepositReverts() public {
        vm.prank(user1);
        vm.expectRevert("zero deposit");
        vault.deposit{value: 0}();
    }

    function testZeroWithdrawReverts() public {
        vm.startPrank(user1);
        vault.deposit{value: 1 ether}();

        vm.expectRevert("zero withdraw");
        vault.withdraw(0);

        vm.stopPrank();
    }

    function testFuzzDepositUpdatesBalance(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(user1, uint256(amount));    

        vm.prank(user1);
        vault.deposit{value: uint256(amount)}();

        assertEq(vault.balanceOf(user1), uint256(amount));
        assertEq(vault.totalAssets(), uint256(amount));
    }

    function testFuzzWithdrawReducesBalance(uint96 depositAmount, uint96 withdrawAmount) public {
        vm.assume(depositAmount > 0);
        vm.assume(withdrawAmount > 0);
        vm.assume(withdrawAmount <= depositAmount);

        vm.deal(user1, uint256(depositAmount));

        vm.startPrank(user1);
        vault.deposit{value: uint256(depositAmount)}();
        vault.withdraw(uint256(withdrawAmount));
        vm.stopPrank();

        assertEq(vault.balanceOf(user1), uint256(depositAmount) - uint256(withdrawAmount));
        assertEq(vault.totalAssets(), uint256(depositAmount) - uint256(withdrawAmount));
    }

    function testMultipleUsersAccountingStaysConsistent() public {
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

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
        assertEq(vault.totalAssets(), expectedTotal);
    }

    function testUserActionsDoNotChangeOtherUserBalance() public {
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        vm.prank(user1);
        vault.deposit{value: 2 ether}();

        vm.prank(user2);
        vault.deposit{value: 4 ether}();

        uint256 user2BalanceBefore = vault.balanceOf(user2);

        vm.prank(user1);
        vault.withdraw(1 ether);

        assertEq(vault.balanceOf(user2), user2BalanceBefore);
    }
}