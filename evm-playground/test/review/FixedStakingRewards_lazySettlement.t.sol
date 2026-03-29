// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/review/FixedStakingRewards.sol";
import "../../src/review/interfaces/IChainlinkAggregator.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC20LazySettlement is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockAggregatorLazySettlement is IChainlinkAggregator {
    uint8 internal _decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function setDecimals(uint8 d) external {
        _decimals = d;
    }

    function setLatestAnswer(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRound() external pure returns (uint256) {
        return 0;
    }

    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return _updatedAt;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }
}

contract FixedStakingRewardsLazySettlementTest is Test {
    FixedStakingRewards stakingRewards;
    MockERC20LazySettlement stakingToken;
    MockERC20LazySettlement rewardsToken;
    MockAggregatorLazySettlement mockAggregator;

    address owner = address(this);
    address user1 = address(0x1);

    function setUp() public {
        stakingToken = new MockERC20LazySettlement("Staking Token", "STK");
        rewardsToken = new MockERC20LazySettlement("Rewards Token", "RWD");
        mockAggregator = new MockAggregatorLazySettlement(8, int256(1e8 / 2), block.timestamp);

        stakingRewards =
            new FixedStakingRewards(owner, address(rewardsToken), address(stakingToken), address(mockAggregator));

        stakingToken.mint(user1, 1_000e18);
        rewardsToken.mint(owner, 10_000e18);

        stakingRewards.addToWhitelist(user1);

        vm.warp(3 days);
        mockAggregator.setLatestAnswer(1e8 / 2, block.timestamp);

        stakingRewards.setRewardYieldForYear(1e18);
        rewardsToken.approve(address(stakingRewards), type(uint256).max);
        stakingRewards.supplyRewards(5_000e18);
        stakingRewards.releaseRewards();

        vm.startPrank(user1);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
        stakingRewards.stake(100e18);
        vm.stopPrank();
    }

    function testLazySettlementAcrossApyResetPreservesAccruedRewards() public {
        uint256 oldRate = stakingRewards.rewardRate();
        assertEq(oldRate, uint256(2e18) / uint256(365 days));

        skip(1 days);

        stakingRewards.setRewardYieldForYear(2e18);

        uint256 newRate = stakingRewards.rewardRate();
        assertEq(newRate, uint256(4e18) / uint256(365 days));

        skip(1 days);

        uint256 expected = (100e18 * ((oldRate * 1 days) + (newRate * 1 days))) / 1e18;

        uint256 earnedBeforeClaim = stakingRewards.earned(user1);
        assertEq(earnedBeforeClaim, expected);

        uint256 rewardsBalanceBefore = rewardsToken.balanceOf(user1);

        vm.prank(user1);
        stakingRewards.getReward();

        uint256 rewardsBalanceAfter = rewardsToken.balanceOf(user1);
        assertEq(rewardsBalanceAfter - rewardsBalanceBefore, expected);
        assertEq(stakingRewards.rewards(user1), 0);
    }
}
