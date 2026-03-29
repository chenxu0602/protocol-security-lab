// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FixedStakingRewards} from "../../src/review/FixedStakingRewards.sol";
import {ERC20, IERC20Errors} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IChainlinkAggregator} from "../../src/review/interfaces/IChainlinkAggregator.sol";

import {
    CannotWithdrawStakingToken,
    InvalidPriceFeed,
    NotWhitelisted
} from "../../src/review/FixedStakingRewards.sol";

contract MockChainlinkAggregatorReview is IChainlinkAggregator {
    uint80 public roundId;
    uint8 public keyDecimals;

    struct Entry {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    mapping(uint256 => Entry) public entries;

    bool public latestRoundDataShouldRevert;

    function setLatestAnswer(int256 answer, uint256 timestamp) external {
        roundId++;
        entries[roundId] = Entry({
            roundId: roundId,
            answer: answer,
            startedAt: timestamp,
            updatedAt: timestamp,
            answeredInRound: roundId
        });
    }

    function setDecimals(uint8 decimals_) external {
        keyDecimals = decimals_;
    }

    function setLatestRoundDataShouldRevert(bool shouldRevert) external {
        latestRoundDataShouldRevert = shouldRevert;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (latestRoundDataShouldRevert) {
            revert("latestRoundData reverted");
        }

        return getRoundData(roundId);
    }

    function decimals() external view returns (uint8) {
        return keyDecimals;
    }

    function latestRound() external view returns (uint256) {
        return roundId;
    }

    function getAnswer(uint256 roundId_) external view returns (int256) {
        return entries[roundId_].answer;
    }

    function getTimestamp(uint256 roundId_) external view returns (uint256) {
        return entries[roundId_].updatedAt;
    }

    function getRoundData(uint80 roundId_) public view returns (uint80, int256, uint256, uint256, uint80) {
        Entry memory entry = entries[roundId_];
        return (entry.roundId, entry.answer, entry.startedAt, entry.updatedAt, entry.answeredInRound);
    }
}

contract MockERC20Review is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

contract FixedStakingRewardsReviewTest is Test {
    FixedStakingRewards internal stakingRewards;
    MockERC20Review internal rewardsToken;
    MockERC20Review internal stakingToken;
    MockChainlinkAggregatorReview internal aggregator;

    address internal owner;
    address internal user1;
    address internal user2;

    uint256 internal constant INITIAL_REWARDS_SUPPLY = 10_000e18;
    uint256 internal constant INITIAL_STAKING_SUPPLY = 10_000e18;

    function setUp() public {
        vm.warp(1_000_000_000);

        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        rewardsToken = new MockERC20Review("RewardsToken", "RT", INITIAL_REWARDS_SUPPLY);
        stakingToken = new MockERC20Review("StakingToken", "ST", INITIAL_STAKING_SUPPLY);
        aggregator = new MockChainlinkAggregatorReview();

        aggregator.setDecimals(8);
        aggregator.setLatestAnswer(5e7, block.timestamp);

        stakingRewards =
            new FixedStakingRewards(owner, address(rewardsToken), address(stakingToken), address(aggregator));

        rewardsToken.approve(address(stakingRewards), type(uint256).max);
        stakingToken.transfer(user1, 1_000e18);
    }

    function test_Review_WhitelistRemovalTrapsPrincipalAndAccruedRewards() public {
        _fundAndStake(user1, 100e18, 2_000e18);

        skip(3 days);
        stakingRewards.releaseRewards();

        uint256 accruedRewards = stakingRewards.earned(user1);
        assertGt(accruedRewards, 0, "expected accrued rewards before whitelist removal");

        stakingRewards.removeFromWhitelist(user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        stakingRewards.withdraw(1e18);

        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        stakingRewards.getReward();

        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        stakingRewards.exit();
        vm.stopPrank();

        assertEq(stakingRewards.balanceOf(user1), 100e18, "principal remains stuck");
        assertEq(stakingRewards.earned(user1), accruedRewards, "accrued rewards remain unclaimable");
    }

    function test_Review_ReclaimDrainsRewardBackingNeededForCheckpointedClaims() public {
        _fundAndStake(user1, 100e18, 2_000e18);

        skip(3 days);
        _checkpointRewards(user1);

        uint256 storedRewards = stakingRewards.rewards(user1);
        assertGt(storedRewards, 0, "expected checkpointed rewards before reclaim");

        stakingRewards.reclaim();

        assertEq(stakingRewards.rewardRate(), 0, "reclaim zeroes future reward rate");
        assertEq(stakingRewards.targetRewardApy(), 0, "reclaim zeroes target apy");
        assertEq(stakingRewards.rewardsAvailableDate(), block.timestamp, "reclaim makes rewards immediately available");
        assertEq(rewardsToken.balanceOf(address(stakingRewards)), 0, "reclaim drains reward reserves");
        assertEq(stakingRewards.earned(user1), storedRewards, "accounting still shows a claim");

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(stakingRewards), 0, storedRewards
            )
        );
        stakingRewards.getReward();
    }

    function test_Review_RecoverERC20CanDrainRewardBackingNeededForClaims() public {
        _fundAndStake(user1, 100e18, 2_000e18);

        skip(3 days);
        _checkpointRewards(user1);

        uint256 storedRewards = stakingRewards.rewards(user1);
        uint256 contractRewardBalance = rewardsToken.balanceOf(address(stakingRewards));

        assertGt(storedRewards, 0, "expected checkpointed rewards before recovery");
        assertGe(contractRewardBalance, storedRewards, "contract should be able to pay before recovery");

        stakingRewards.recoverERC20(address(rewardsToken), contractRewardBalance);

        assertEq(rewardsToken.balanceOf(address(stakingRewards)), 0, "reward token reserves were fully recovered");
        assertEq(stakingRewards.earned(user1), storedRewards, "accounting still exposes a reward claim");

        stakingRewards.releaseRewards();

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(stakingRewards), 0, storedRewards
            )
        );
        stakingRewards.getReward();
    }

    function test_Review_WithdrawSwallowsRebalanceFailureFromExternalSelfCall() public {
        _fundAndStake(user1, 100e18, 2_000e18);

        skip(1 days);
        stakingRewards.releaseRewards();

        uint256 rewardRateBeforeWithdraw = stakingRewards.rewardRate();
        aggregator.setLatestRoundDataShouldRevert(true);

        vm.prank(user1);
        stakingRewards.withdraw(40e18);

        assertEq(stakingRewards.balanceOf(user1), 60e18, "withdraw still succeeds");
        assertEq(stakingToken.balanceOf(user1), 940e18, "principal is returned despite rebalance failure");
        assertEq(stakingRewards.rewardRate(), rewardRateBeforeWithdraw, "swallowed rebalance failure leaves rate unchanged");

        vm.expectRevert(bytes("latestRoundData reverted"));
        stakingRewards.rebalance();
    }

    function test_Review_RecoverERC20StillBlocksStakingTokenRecovery() public {
        vm.expectRevert(abi.encodeWithSelector(CannotWithdrawStakingToken.selector, address(stakingToken)));
        stakingRewards.recoverERC20(address(stakingToken), 1e18);
    }

    function test_Review_DirectRebalanceStillFailsOnInvalidFeed() public {
        stakingRewards.setRewardYieldForYear(1e18);
        aggregator.setLatestAnswer(5e7, block.timestamp - 2 days);

        vm.expectRevert(abi.encodeWithSelector(InvalidPriceFeed.selector, block.timestamp - 2 days, int256(5e7)));
        stakingRewards.rebalance();
    }

    function _fundAndStake(address user, uint256 stakeAmount, uint256 rewardFunding) internal {
        stakingRewards.setRewardYieldForYear(1e18);
        stakingRewards.supplyRewards(rewardFunding);
        stakingRewards.addToWhitelist(user);

        vm.startPrank(user);
        stakingToken.approve(address(stakingRewards), stakeAmount);
        stakingRewards.stake(stakeAmount);
        vm.stopPrank();
    }

    function _checkpointRewards(address user) internal {
        vm.prank(user);
        stakingRewards.transfer(user2, 0);
    }
}
