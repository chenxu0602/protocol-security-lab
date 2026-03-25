// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ReentrantBuggyVault {
    mapping(address => uint256) public balanceOf;
    uint256 public totalAssets;

    function deposit() external payable {
        require(msg.value > 0, "zero deposit");
        balanceOf[msg.sender] += msg.value;
        totalAssets += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "zero withdraw");
        require(balanceOf[msg.sender] >= amount, "insufficient balance");

        // BUG: interaction before effects
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");

        unchecked {
            balanceOf[msg.sender] -= amount;
            totalAssets -= amount;
        }
    }
}