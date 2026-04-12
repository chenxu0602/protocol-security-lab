// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import {Test} from "forge-std/Test.sol";

import {BaseStrategy} from "../../src/review/BaseStrategy.sol";
import {TokenizedStrategy} from "../../src/review/TokenizedStrategy.sol";
import {MockERC20} from "../../src/review/MockERC20.sol";
import {IStrategy} from "../../src/review/interfaces/IStrategy.sol";

contract MockFactory {
    uint16 public protocolFeeBps;
    address public protocolFeeRecipient;

    function protocol_fee_config() external view returns (uint16, address) {
        return (protocolFeeBps, protocolFeeRecipient);
    }

    function setProtocolFeeConfig(uint16 _protocolFeeBps, address _recipient) external {
        protocolFeeBps = _protocolFeeBps;
        protocolFeeRecipient = _recipient;
    }
}

contract AddressSpacer {}

contract HonestHarnessStrategy is BaseStrategy {
    constructor(address _asset, string memory _name) BaseStrategy(_asset, _name) {}

    function _deployFunds(uint256) internal override {}

    function _freeFunds(uint256) internal override {}

    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        return asset.balanceOf(address(this));
    }
}

contract ConfigurableMockStrategy is BaseStrategy {
    enum ReportMode {
        Honest,
        Stale,
        Overvalue,
        Undervalue
    }

    ReportMode public reportMode;
    uint256 public staleTotalAssets;
    uint256 public basisPointDelta;

    constructor(address _asset, string memory _name) BaseStrategy(_asset, _name) {
        reportMode = ReportMode.Honest;
        basisPointDelta = 5_000;
    }

    function setMode(ReportMode _reportMode) external {
        reportMode = _reportMode;
    }

    function snapshotStaleTotalAssets() external {
        staleTotalAssets = asset.balanceOf(address(this));
    }

    function setStaleTotalAssets(uint256 _staleTotalAssets) external {
        staleTotalAssets = _staleTotalAssets;
    }

    function setBasisPointDelta(uint256 _basisPointDelta) external {
        basisPointDelta = _basisPointDelta;
    }

    function actualAssets() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _deployFunds(uint256) internal override {}

    function _freeFunds(uint256) internal override {}

    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        uint256 actual = asset.balanceOf(address(this));

        if (reportMode == ReportMode.Stale) {
            return staleTotalAssets;
        }

        if (reportMode == ReportMode.Overvalue) {
            return actual + ((actual * basisPointDelta) / 10_000);
        }

        if (reportMode == ReportMode.Undervalue) {
            return actual - ((actual * basisPointDelta) / 10_000);
        }

        return actual;
    }
}

contract YearnV3Week8 is Test {
    address internal constant TOKENIZED_STRATEGY_ADDRESS =
        0x2e234DAe75C793f67A35089C9d99245E1C58470b;
    uint256 internal constant STARTING_BALANCE = 1_000 ether;
    uint256 internal constant HALF_UNLOCK = 5 days;
    uint256 internal constant FULL_UNLOCK = 10 days + 1;

    MockERC20 internal asset;
    MockFactory internal factory;

    HonestHarnessStrategy internal honestHarness;
    ConfigurableMockStrategy internal mockStrategy;
    IStrategy internal honestVault;
    IStrategy internal mockVault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    struct FrequencyScenarioResult {
        uint256 feeShares;
        uint256 lockedShares;
        uint256 profitUnlockingRate;
        uint256 fullProfitUnlockDate;
        uint256 aliceClaim;
        uint256 bobClaim;
    }

    function setUp() public {
        vm.warp(1_700_000_000);

        asset = new MockERC20("Mock Asset", "MA", 18);
        new AddressSpacer();
        factory = new MockFactory();
        factory.setProtocolFeeConfig(0, address(0));

        TokenizedStrategy implementation = new TokenizedStrategy(address(factory));
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(implementation).code);

        honestHarness = new HonestHarnessStrategy(address(asset), "Honest Yearn Strategy");
        mockStrategy = new ConfigurableMockStrategy(address(asset), "Configurable Yearn Strategy");

        honestVault = IStrategy(address(honestHarness));
        mockVault = IStrategy(address(mockStrategy));

        _mintAndApprove(alice);
        _mintAndApprove(bob);
        _mintAndApprove(carol);
    }

    function testHonestHarness_MultiUser_NoOpReportDoesNotShiftClaims() public {
        // Type: bounded reconciliation
        // Hypothesis: an honest no-op report should not shift multi-user claims or supply.
        _deposit(honestVault, alice, 100 ether);
        _deposit(honestVault, bob, 100 ether);

        uint256 aliceClaimBefore = _claim(honestVault, alice);
        uint256 bobClaimBefore = _claim(honestVault, bob);
        uint256 supplyBefore = honestVault.totalSupply();

        honestVault.report();

        assertEq(_claim(honestVault, alice), aliceClaimBefore);
        assertEq(_claim(honestVault, bob), bobClaimBefore);
        assertEq(honestVault.totalSupply(), supplyBefore);
        assertEq(honestVault.totalAssets(), 200 ether);
    }

    function testHonestMode_MultiUser_MidUnlockLateDepositorGetsFewerShares() public {
        mockStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);

        _deposit(mockVault, alice, 100 ether);
        asset.mint(address(mockStrategy), 100 ether);
        mockVault.report();

        vm.warp(block.timestamp + HALF_UNLOCK);

        uint256 bobShares = _deposit(mockVault, bob, 100 ether);

        assertLt(bobShares, 100 ether);
        assertGt(_claim(mockVault, alice), _claim(mockVault, bob));
    }

    function testHonestMode_MultiUser_ImmediateLateDepositorSharesStillLockedValue() public {
        mockStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);

        _deposit(mockVault, alice, 100 ether);
        asset.mint(address(mockStrategy), 100 ether);
        mockVault.report();

        uint256 bobShares = _deposit(mockVault, bob, 100 ether);

        assertEq(bobShares, 100 ether);

        vm.warp(block.timestamp + FULL_UNLOCK);

        uint256 aliceClaim = _claim(mockVault, alice);
        uint256 bobClaim = _claim(mockVault, bob);

        assertEq(aliceClaim, bobClaim);
        assertGt(aliceClaim, 100 ether);
        assertLt(aliceClaim, 150 ether);
    }

    function testStaleMode_MultiUser_LateDepositorBuysIntoUnreportedProfitCheaply() public {
        _deposit(mockVault, alice, 100 ether);

        mockStrategy.setMode(ConfigurableMockStrategy.ReportMode.Stale);
        mockStrategy.setStaleTotalAssets(100 ether);

        asset.mint(address(mockStrategy), 100 ether);

        uint256 bobShares = _deposit(mockVault, bob, 100 ether);
        assertEq(bobShares, 100 ether);

        mockStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);
        mockVault.report();

        vm.warp(block.timestamp + FULL_UNLOCK);

        uint256 aliceClaim = _claim(mockVault, alice);
        uint256 bobClaim = _claim(mockVault, bob);

        assertEq(aliceClaim, bobClaim);
        assertGt(aliceClaim, 100 ether);
        assertLt(aliceClaim, 150 ether);
    }

    function testStaleMode_MultiUser_DelayedRealizationBenefitsLateEntrantVsHonestPricing() public {
        _deposit(mockVault, alice, 100 ether);
        asset.mint(address(mockStrategy), 100 ether);

        mockStrategy.setMode(ConfigurableMockStrategy.ReportMode.Stale);
        mockStrategy.setStaleTotalAssets(100 ether);
        uint256 staleBobShares = _deposit(mockVault, bob, 100 ether);

        vm.roll(block.number + 1);

        ConfigurableMockStrategy comparisonStrategy =
            new ConfigurableMockStrategy(address(asset), "Comparison Honest Strategy");
        IStrategy comparisonVault = IStrategy(address(comparisonStrategy));
        _approve(address(comparisonVault), alice);
        _approve(address(comparisonVault), bob);

        _deposit(comparisonVault, alice, 100 ether);
        asset.mint(address(comparisonStrategy), 100 ether);
        comparisonStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);
        comparisonVault.report();
        vm.warp(block.timestamp + HALF_UNLOCK);
        uint256 honestBobShares = _deposit(comparisonVault, bob, 100 ether);

        assertGt(staleBobShares, honestBobShares);
    }

    function testOvervalueMode_MultiUser_InflatedReportOverchargesLateDepositor() public {
        _deposit(mockVault, alice, 100 ether);

        mockStrategy.setMode(ConfigurableMockStrategy.ReportMode.Overvalue);
        mockStrategy.setBasisPointDelta(10_000);
        mockVault.report();

        vm.warp(block.timestamp + HALF_UNLOCK);

        uint256 bobShares = _deposit(mockVault, bob, 100 ether);
        assertLt(bobShares, 100 ether);

        mockStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);
        mockVault.report();

        uint256 bobClaimAfterCorrection = _claim(mockVault, bob);
        assertLt(bobClaimAfterCorrection, 100 ether);
        assertGt(_claim(mockVault, alice), bobClaimAfterCorrection);
    }

    function testOptimisticReport_OverMintsFeeSharesAndChangesUserOutcomes() public {
        (ConfigurableMockStrategy honestStrategy, IStrategy honestComparisonVault) =
            _deployComparisonStrategy("Honest Fee Comparison");
        (ConfigurableMockStrategy optimisticStrategy, IStrategy optimisticComparisonVault) =
            _deployComparisonStrategy("Optimistic Fee Comparison");

        honestStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);
        optimisticStrategy.setMode(ConfigurableMockStrategy.ReportMode.Overvalue);
        optimisticStrategy.setBasisPointDelta(10_000);

        _deposit(honestComparisonVault, alice, 100 ether);
        _deposit(optimisticComparisonVault, alice, 100 ether);

        asset.mint(address(honestStrategy), 100 ether);
        asset.mint(address(optimisticStrategy), 100 ether);

        honestComparisonVault.report();
        optimisticComparisonVault.report();

        uint256 honestFeeShares = honestComparisonVault.balanceOf(address(this));
        uint256 optimisticFeeShares = optimisticComparisonVault.balanceOf(address(this));
        uint256 honestLockedShares = honestComparisonVault.balanceOf(address(honestStrategy));
        uint256 optimisticLockedShares = optimisticComparisonVault.balanceOf(address(optimisticStrategy));

        assertGt(optimisticFeeShares, honestFeeShares);
        assertGt(optimisticLockedShares, honestLockedShares);

        vm.warp(block.timestamp + HALF_UNLOCK);

        _deposit(honestComparisonVault, bob, 100 ether);
        _deposit(optimisticComparisonVault, bob, 100 ether);

        optimisticStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);
        optimisticComparisonVault.report();

        vm.warp(block.timestamp + FULL_UNLOCK);

        uint256 honestAliceClaim = _claim(honestComparisonVault, alice);
        uint256 honestBobClaim = _claim(honestComparisonVault, bob);
        uint256 optimisticAliceClaim = _claim(optimisticComparisonVault, alice);
        uint256 optimisticBobClaim = _claim(optimisticComparisonVault, bob);

        assertGt(optimisticComparisonVault.balanceOf(address(this)), honestFeeShares);
        assertLe(optimisticAliceClaim, honestAliceClaim);
        assertLe(optimisticBobClaim, honestBobClaim);
    }

    function testReportTiming_ChangesUnlockAndDepositorOutcomesForSameEconomicPath() public {
        // Type: characterization
        // Hypothesis: for the same honest economic path, report timing can change unlock
        // schedule and user-level outcomes without implying broken accounting.
        (ConfigurableMockStrategy earlyStrategy, IStrategy earlyVault) =
            _deployComparisonStrategy("Early Report Strategy");
        (ConfigurableMockStrategy lateStrategy, IStrategy lateVault) =
            _deployComparisonStrategy("Late Report Strategy");

        earlyStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);
        lateStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);

        _deposit(earlyVault, alice, 100 ether);
        _deposit(lateVault, alice, 100 ether);

        asset.mint(address(earlyStrategy), 100 ether);
        asset.mint(address(lateStrategy), 100 ether);

        earlyVault.report();

        vm.warp(block.timestamp + HALF_UNLOCK);

        assertGt(earlyVault.unlockedShares(), 0);
        assertEq(lateVault.unlockedShares(), 0);

        uint256 earlyBobShares = _deposit(earlyVault, bob, 100 ether);
        uint256 lateBobShares = _deposit(lateVault, bob, 100 ether);

        assertLt(earlyBobShares, lateBobShares);

        lateVault.report();

        vm.warp(block.timestamp + FULL_UNLOCK);

        uint256 earlyAliceClaim = _claim(earlyVault, alice);
        uint256 earlyBobClaim = _claim(earlyVault, bob);
        uint256 lateAliceClaim = _claim(lateVault, alice);
        uint256 lateBobClaim = _claim(lateVault, bob);

        assertGt(earlyAliceClaim, lateAliceClaim);
        assertLt(earlyBobClaim, lateBobClaim);

        assertLt(earlyAliceClaim + earlyBobClaim, earlyVault.totalAssets());
        assertLt(lateAliceClaim + lateBobClaim, lateVault.totalAssets());
    }

    function testReportFrequency_SamePnLPath_ChangesUnlockScheduleAtDay10() public {
        (FrequencyScenarioResult memory oneReport, FrequencyScenarioResult memory twoReports) =
            _runSamePnLPathDifferentReportFrequency();

        assertEq(oneReport.lockedShares, 90 ether);
        assertLt(twoReports.lockedShares, oneReport.lockedShares);
        assertGt(twoReports.lockedShares, 0);

        assertEq(oneReport.feeShares, 10 ether);
        assertLt(twoReports.feeShares, oneReport.feeShares);
        assertGt(twoReports.feeShares, 0);

        assertLt(twoReports.fullProfitUnlockDate, oneReport.fullProfitUnlockDate);
        assertLt(twoReports.profitUnlockingRate, oneReport.profitUnlockingRate);
    }

    function testReportFrequency_SamePnLPath_ChangesLateEntrantAndIncumbentClaims() public {
        (FrequencyScenarioResult memory oneReport, FrequencyScenarioResult memory twoReports) =
            _runSamePnLPathDifferentReportFrequency();

        assertGt(twoReports.aliceClaim, oneReport.aliceClaim);
        assertLt(twoReports.bobClaim, oneReport.bobClaim);
    }

    function _mintAndApprove(address user) internal {
        asset.mint(user, STARTING_BALANCE);
        _approve(address(honestVault), user);
        _approve(address(mockVault), user);
    }

    function _runSamePnLPathDifferentReportFrequency()
        internal
        returns (FrequencyScenarioResult memory oneReport, FrequencyScenarioResult memory twoReports)
    {
        (ConfigurableMockStrategy oneReportStrategy, IStrategy oneReportVault) =
            _deployComparisonStrategy("One Report Frequency Strategy");
        (ConfigurableMockStrategy twoReportStrategy, IStrategy twoReportVault) =
            _deployComparisonStrategy("Two Report Frequency Strategy");

        oneReportStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);
        twoReportStrategy.setMode(ConfigurableMockStrategy.ReportMode.Honest);

        asset.mint(alice, 1_000 ether);
        asset.mint(bob, 1_000 ether);

        _deposit(oneReportVault, alice, 1_000 ether);
        _deposit(twoReportVault, alice, 1_000 ether);

        vm.warp(block.timestamp + 5 days);

        asset.mint(address(oneReportStrategy), 50 ether);
        asset.mint(address(twoReportStrategy), 50 ether);

        twoReportVault.report();

        vm.warp(block.timestamp + 5 days);

        asset.mint(address(oneReportStrategy), 50 ether);
        asset.mint(address(twoReportStrategy), 50 ether);

        oneReportVault.report();
        twoReportVault.report();

        oneReport = FrequencyScenarioResult({
            feeShares: oneReportVault.balanceOf(address(this)),
            lockedShares: oneReportVault.balanceOf(address(oneReportStrategy)),
            profitUnlockingRate: oneReportVault.profitUnlockingRate(),
            fullProfitUnlockDate: oneReportVault.fullProfitUnlockDate(),
            aliceClaim: 0,
            bobClaim: 0
        });

        twoReports = FrequencyScenarioResult({
            feeShares: twoReportVault.balanceOf(address(this)),
            lockedShares: twoReportVault.balanceOf(address(twoReportStrategy)),
            profitUnlockingRate: twoReportVault.profitUnlockingRate(),
            fullProfitUnlockDate: twoReportVault.fullProfitUnlockDate(),
            aliceClaim: 0,
            bobClaim: 0
        });

        _deposit(oneReportVault, bob, 1_000 ether);
        _deposit(twoReportVault, bob, 1_000 ether);

        vm.warp(block.timestamp + FULL_UNLOCK);

        oneReport.aliceClaim = _claim(oneReportVault, alice);
        oneReport.bobClaim = _claim(oneReportVault, bob);
        twoReports.aliceClaim = _claim(twoReportVault, alice);
        twoReports.bobClaim = _claim(twoReportVault, bob);
    }

    function _deployComparisonStrategy(string memory name)
        internal
        returns (ConfigurableMockStrategy strategy, IStrategy vault)
    {
        strategy = new ConfigurableMockStrategy(address(asset), name);
        vault = IStrategy(address(strategy));
        _approve(address(vault), alice);
        _approve(address(vault), bob);
        _approve(address(vault), carol);
    }

    function _approve(address vault, address user) internal {
        vm.prank(user);
        asset.approve(vault, type(uint256).max);
    }

    function _deposit(IStrategy vault, address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        return vault.deposit(assets, user);
    }

    function _claim(IStrategy vault, address user) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(user));
    }
}
