// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BuggyVault {
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

        balanceOf[msg.sender] -= amount;
        // BUG: totalAssets is not updated
        totalAssets -= amount;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");
    }
}