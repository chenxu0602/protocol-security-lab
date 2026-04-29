// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

interface Vm {
    function addr(uint256 privateKey) external returns (address);

    function deal(address account, uint256 newBalance) external;

    function expectRevert(bytes calldata revertData) external;

    function label(address account, string calldata newLabel) external;

    function prank(address msgSender) external;

    function startPrank(address msgSender) external;

    function stopPrank() external;

    function warp(uint256 newTimestamp) external;
}
