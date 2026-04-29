// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { UmaCtfAdapter } from "polymarket/uma-ctf-adapter/src/UmaCtfAdapter.sol";
import { IConditionalTokens } from "polymarket/uma-ctf-adapter/src/interfaces/IConditionalTokens.sol";
import {
    IOptimisticOracleV2,
    Request,
    RequestSettings
} from "polymarket/uma-ctf-adapter/src/interfaces/IOptimisticOracleV2.sol";
import { IOptimisticRequester } from "polymarket/uma-ctf-adapter/src/interfaces/IOptimisticRequester.sol";

interface IERC1155BalanceOf {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

contract MockFinder {
    mapping(bytes32 => address) internal implementations;

    function changeImplementationAddress(bytes32 interfaceName, address implementationAddress) external {
        implementations[interfaceName] = implementationAddress;
    }

    function getImplementationAddress(bytes32 interfaceName) external view returns (address) {
        return implementations[interfaceName];
    }
}

contract MockAddressWhitelist {
    mapping(address => bool) internal whitelist;
    address[] internal members;

    function addToWhitelist(address account) external {
        if (!whitelist[account]) {
            whitelist[account] = true;
            members.push(account);
        }
    }

    function removeFromWhitelist(address account) external {
        whitelist[account] = false;
    }

    function isOnWhitelist(address account) external view returns (bool) {
        return whitelist[account];
    }

    function getWhitelist() external view returns (address[] memory) {
        return members;
    }
}

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");

        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }

        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract MockOptimisticOracleV2 is IOptimisticOracleV2 {
    struct RequestState {
        Request request;
        bool hasPriceValue;
        int256 settledPrice;
    }

    mapping(bytes32 => RequestState) internal requests;
    uint256 internal immutable defaultLivenessValue;

    constructor(uint256 defaultLiveness_) {
        defaultLivenessValue = defaultLiveness_;
    }

    function defaultLiveness() external view returns (uint256) {
        return defaultLivenessValue;
    }

    function requestPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        IERC20 currency,
        uint256 reward
    ) external returns (uint256 totalBond) {
        Request storage request = requests[_key(msg.sender, identifier, timestamp, ancillaryData)].request;
        request.currency = currency;
        request.reward = reward;
        return 0;
    }

    function proposePrice(address, bytes32, uint256, bytes memory, int256) external pure returns (uint256 totalBond) {
        return 0;
    }

    function disputePrice(address, bytes32, uint256, bytes memory) external pure returns (uint256 totalBond) {
        return 0;
    }

    function setBond(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, uint256 bond)
        external
        returns (uint256 totalBond)
    {
        requests[_key(msg.sender, identifier, timestamp, ancillaryData)].request.requestSettings.bond = bond;
        return bond;
    }

    function setEventBased(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData) external {
        requests[_key(msg.sender, identifier, timestamp, ancillaryData)].request.requestSettings.eventBased = true;
    }

    function setCallbacks(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        bool callbackOnPriceProposed,
        bool callbackOnPriceDisputed,
        bool callbackOnPriceSettled
    ) external {
        RequestSettings storage settings =
            requests[_key(msg.sender, identifier, timestamp, ancillaryData)].request.requestSettings;
        settings.callbackOnPriceProposed = callbackOnPriceProposed;
        settings.callbackOnPriceDisputed = callbackOnPriceDisputed;
        settings.callbackOnPriceSettled = callbackOnPriceSettled;
    }

    function setCustomLiveness(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, uint256 customLiveness)
        external
    {
        requests[_key(msg.sender, identifier, timestamp, ancillaryData)].request.requestSettings.customLiveness =
            customLiveness;
    }

    function settle(address, bytes32, uint256, bytes memory) external pure returns (uint256 payout) {
        return 0;
    }

    function settleAndGetPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external
        returns (int256)
    {
        RequestState storage state = requests[_key(msg.sender, identifier, timestamp, ancillaryData)];
        require(state.hasPriceValue, "not ready");
        return state.settledPrice;
    }

    function getRequest(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external
        view
        returns (Request memory)
    {
        return requests[_key(requester, identifier, timestamp, ancillaryData)].request;
    }

    function hasPrice(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external
        view
        returns (bool)
    {
        return requests[_key(requester, identifier, timestamp, ancillaryData)].hasPriceValue;
    }

    function setResolvedPrice(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, int256 price)
        external
    {
        RequestState storage state = requests[_key(requester, identifier, timestamp, ancillaryData)];
        state.hasPriceValue = true;
        state.settledPrice = price;
        state.request.resolvedPrice = price;
    }

    function triggerDispute(
        address requester,
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        uint256 refund
    ) external {
        RequestState storage state = requests[_key(requester, identifier, timestamp, ancillaryData)];
        require(state.request.requestSettings.callbackOnPriceDisputed, "callback disabled");
        IOptimisticRequester(requester).priceDisputed(identifier, timestamp, ancillaryData, refund);
    }

    function _key(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(requester, identifier, timestamp, ancillaryData));
    }
}

contract PolymarketResolutionScenariosTest is Test {
    string internal constant CONDITIONAL_TOKENS_ARTIFACT =
        "lib/polymarket/ctf-exchange-v2/artifacts/ConditionalTokens.json";

    address internal admin = address(1);
    MockERC20 internal usdc;
    IConditionalTokens internal ctf;
    MockFinder internal finder;
    MockAddressWhitelist internal whitelist;
    MockOptimisticOracleV2 internal optimisticOracle;
    UmaCtfAdapter internal adapter;

    bytes32 internal constant IDENTIFIER = "YES_OR_NO_QUERY";
    bytes internal ancillaryData = bytes("q: title: Will it rain tomorrow?");
    bytes internal appendedAncillaryData;
    bytes32 internal questionID;
    bytes32 internal conditionId;
    bytes4 internal constant PAUSED_SELECTOR = bytes4(keccak256("Paused()"));
    bytes4 internal constant SAFETY_PERIOD_NOT_PASSED_SELECTOR =
        bytes4(keccak256("SafetyPeriodNotPassed()"));

    function setUp() public {
        vm.label(admin, "admin");

        usdc = new MockERC20("USD Coin", "USDC");
        ctf = IConditionalTokens(_deployConditionalTokens());
        finder = new MockFinder();
        whitelist = new MockAddressWhitelist();
        optimisticOracle = new MockOptimisticOracleV2(2 hours);

        whitelist.addToWhitelist(address(usdc));
        finder.changeImplementationAddress("CollateralWhitelist", address(whitelist));

        appendedAncillaryData = abi.encodePacked(ancillaryData, ",initializer:", _toUtf8BytesAddress(admin));
        questionID = keccak256(appendedAncillaryData);

        vm.startPrank(admin);
        adapter = new UmaCtfAdapter(address(ctf), address(finder), address(optimisticOracle));
        usdc.mint(admin, 1_000_000_000);
        usdc.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    function test_disputeResetThenAdminResetAdvancesRequestTimestampAndClearsRefund() public {
        vm.prank(admin);
        adapter.initialize(ancillaryData, address(usdc), 1_000_000, 0, 0);
        conditionId = ctf.getConditionId(address(adapter), questionID, 2);

        uint256 firstTimestamp = adapter.getQuestion(questionID).requestTimestamp;
        bytes memory firstQuestionAncillary = adapter.getQuestion(questionID).ancillaryData;

        vm.warp(block.timestamp + 1);
        optimisticOracle.triggerDispute(address(adapter), IDENTIFIER, firstTimestamp, firstQuestionAncillary, 0);

        assertTrue(adapter.getQuestion(questionID).reset);
        assertFalse(adapter.getQuestion(questionID).refund);
        assertGt(adapter.getQuestion(questionID).requestTimestamp, firstTimestamp);

        uint256 secondTimestamp = adapter.getQuestion(questionID).requestTimestamp;
        bytes memory secondQuestionAncillary = adapter.getQuestion(questionID).ancillaryData;

        vm.warp(block.timestamp + 1);
        optimisticOracle.triggerDispute(address(adapter), IDENTIFIER, secondTimestamp, secondQuestionAncillary, 1_000_000);

        assertTrue(adapter.getQuestion(questionID).reset);
        assertTrue(adapter.getQuestion(questionID).refund);
        assertEq(adapter.getQuestion(questionID).requestTimestamp, secondTimestamp);

        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        adapter.reset(questionID);

        assertTrue(adapter.getQuestion(questionID).reset);
        assertFalse(adapter.getQuestion(questionID).refund);
        assertGt(adapter.getQuestion(questionID).requestTimestamp, secondTimestamp);
    }

    function test_flagBlocksResolveUntilExplicitlyUnflagged() public {
        vm.prank(admin);
        adapter.initialize(ancillaryData, address(usdc), 0, 0, 0);
        conditionId = ctf.getConditionId(address(adapter), questionID, 2);

        _setResolvedPrice(questionID, 1 ether);

        vm.prank(admin);
        adapter.flag(questionID);

        vm.expectRevert(PAUSED_SELECTOR);
        adapter.resolve(questionID);

        vm.prank(admin);
        adapter.unflag(questionID);

        assertTrue(adapter.ready(questionID));

        adapter.resolve(questionID);

        assertTrue(adapter.getQuestion(questionID).resolved);
        assertEq(ctf.payoutDenominator(conditionId), 1);
    }

    function test_manualResolutionRequiresSafetyPeriodAndIsTerminal() public {
        vm.prank(admin);
        adapter.initialize(ancillaryData, address(usdc), 0, 0, 0);
        conditionId = ctf.getConditionId(address(adapter), questionID, 2);

        vm.prank(admin);
        adapter.flag(questionID);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.expectRevert(SAFETY_PERIOD_NOT_PASSED_SELECTOR);
        vm.prank(admin);
        adapter.resolveManually(questionID, payouts);

        vm.warp(block.timestamp + adapter.SAFETY_PERIOD() + 1);

        vm.prank(admin);
        adapter.resolveManually(questionID, payouts);

        assertTrue(adapter.getQuestion(questionID).resolved);
        assertEq(ctf.payoutDenominator(conditionId), 1);

        vm.expectRevert();
        vm.prank(admin);
        adapter.resolveManually(questionID, payouts);
    }

    function test_redeemabilityRemainsBlockedUntilFinalResolutionAndIsIdempotentAfterwards() public {
        vm.prank(admin);
        adapter.initialize(ancillaryData, address(usdc), 0, 0, 0);
        conditionId = ctf.getConditionId(address(adapter), questionID, 2);

        uint256 amount = 25_000_000;
        uint256 yes = ctf.getPositionId(IERC20(address(usdc)), ctf.getCollectionId(bytes32(0), conditionId, 1));

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.startPrank(admin);
        usdc.approve(address(ctf), amount);
        ctf.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, amount);
        vm.stopPrank();

        uint256[] memory winningIndexSet = new uint256[](1);
        winningIndexSet[0] = 1;

        vm.expectRevert();
        vm.prank(admin);
        ctf.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, winningIndexSet);

        _setResolvedPrice(questionID, 1 ether);
        adapter.resolve(questionID);

        uint256 balanceBefore = usdc.balanceOf(admin);
        vm.prank(admin);
        ctf.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, winningIndexSet);
        uint256 balanceAfterFirstRedeem = usdc.balanceOf(admin);

        assertEq(balanceAfterFirstRedeem - balanceBefore, amount);
        assertEq(IERC1155BalanceOf(address(ctf)).balanceOf(admin, yes), 0);

        vm.prank(admin);
        ctf.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, winningIndexSet);

        assertEq(usdc.balanceOf(admin), balanceAfterFirstRedeem);
        assertEq(IERC1155BalanceOf(address(ctf)).balanceOf(admin, yes), 0);
    }

    function test_rewardProvenanceAcrossDisputeResetCycles() public {
        uint256 reward = 1_000_000;
        uint256 creatorBefore = usdc.balanceOf(admin);

        vm.prank(admin);
        adapter.initialize(ancillaryData, address(usdc), reward, 0, 0);
        conditionId = ctf.getConditionId(address(adapter), questionID, 2);

        assertEq(usdc.balanceOf(address(adapter)), reward);

        uint256 ts1 = adapter.getQuestion(questionID).requestTimestamp;
        bytes memory data1 = adapter.getQuestion(questionID).ancillaryData;

        vm.warp(block.timestamp + 1);
        optimisticOracle.triggerDispute(address(adapter), IDENTIFIER, ts1, data1, reward);

        assertEq(usdc.balanceOf(address(adapter)), reward, "reward left adapter unexpectedly");
        assertFalse(adapter.getQuestion(questionID).refund);

        uint256 ts2 = adapter.getQuestion(questionID).requestTimestamp;
        bytes memory data2 = adapter.getQuestion(questionID).ancillaryData;

        vm.warp(block.timestamp + 1);
        optimisticOracle.triggerDispute(address(adapter), IDENTIFIER, ts2, data2, reward);

        assertTrue(adapter.getQuestion(questionID).refund, "refund flag not set");
        assertEq(usdc.balanceOf(address(adapter)), reward, "reward provenance drifted before reset");

        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        adapter.reset(questionID);

        assertEq(usdc.balanceOf(admin), creatorBefore - reward, "creator net balance should match post-init funded state");
        assertEq(usdc.balanceOf(address(adapter)), reward, "adapter should be refilled for next request");
        assertFalse(adapter.getQuestion(questionID).refund, "refund flag not cleared");
    }

    function _setResolvedPrice(bytes32 questionId, int256 price) internal {
        optimisticOracle.setResolvedPrice(
            address(adapter),
            IDENTIFIER,
            adapter.getQuestion(questionId).requestTimestamp,
            adapter.getQuestion(questionId).ancillaryData,
            price
        );
    }

    function _deployConditionalTokens() internal returns (address deployed) {
        bytes memory creationCode = vm.getCode(CONDITIONAL_TOKENS_ARTIFACT);
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "conditional tokens deploy failed");
    }

    function _toUtf8BytesAddress(address account) internal pure returns (bytes memory str) {
        bytes memory alphabet = "0123456789abcdef";
        str = new bytes(40);
        for (uint256 i = 0; i < 20; ++i) {
            str[i * 2] = alphabet[uint8(uint160(account) / (2 ** (8 * (19 - i) + 4)) & 0xf)];
            str[i * 2 + 1] = alphabet[uint8(uint160(account) / (2 ** (8 * (19 - i))) & 0xf)];
        }
    }
}
