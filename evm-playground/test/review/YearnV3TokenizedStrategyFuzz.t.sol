// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import {Test} from "forge-std/Test.sol";

import {BaseStrategy} from "../../src/review/BaseStrategy.sol";
import {TokenizedStrategy} from "../../src/review/TokenizedStrategy.sol";
import {MockERC20} from "../../src/review/MockERC20.sol";
import {IStrategy} from "../../src/review/interfaces/IStrategy.sol";

contract MockFactoryFuzz {
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

contract AddressSpacerFuzz {}

contract ConfigurableMockStrategyFuzz is BaseStrategy {
    enum ReportMode {
        Honest,
        Stale,
        Overvalue
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

    function setStaleTotalAssets(uint256 _staleTotalAssets) external {
        staleTotalAssets = _staleTotalAssets;
    }

    function setBasisPointDelta(uint256 _basisPointDelta) external {
        basisPointDelta = _basisPointDelta;
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

        return actual;
    }
}

contract YearnV3TokenizedStrategyFuzzTest is Test {
    address internal constant TOKENIZED_STRATEGY_ADDRESS =
        0x2e234DAe75C793f67A35089C9d99245E1C58470b;
    uint256 internal constant STARTING_BALANCE = 20_000 ether;
    uint256 internal constant HALF_UNLOCK = 5 days;

    MockERC20 internal asset;
    MockFactoryFuzz internal factory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_700_000_000);

        asset = new MockERC20("Mock Asset", "MA", 18);
        new AddressSpacerFuzz();
        factory = new MockFactoryFuzz();
        factory.setProtocolFeeConfig(0, address(0));

        TokenizedStrategy implementation = new TokenizedStrategy(address(factory));
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(implementation).code);

        asset.mint(alice, STARTING_BALANCE);
        asset.mint(bob, STARTING_BALANCE);
    }

    function testFuzz_StaleVsHonest_LateEntryGetsMoreSharesWhenReportIsDelayed(
        uint256 aliceAssets,
        uint256 bobAssets,
        uint256 profit
    ) public {
        aliceAssets = bound(aliceAssets, 100 ether, 5_000 ether);
        bobAssets = bound(bobAssets, 100 ether, 5_000 ether);
        profit = bound(profit, 100 ether, 5_000 ether);

        (ConfigurableMockStrategyFuzz staleStrategy, IStrategy staleVault) =
            _deployComparisonStrategy("Stale Fuzz Strategy");
        (ConfigurableMockStrategyFuzz honestStrategy, IStrategy honestVault) =
            _deployComparisonStrategy("Honest Fuzz Strategy");

        _deposit(staleVault, alice, aliceAssets);
        _deposit(honestVault, alice, aliceAssets);

        asset.mint(address(staleStrategy), profit);
        asset.mint(address(honestStrategy), profit);

        staleStrategy.setMode(ConfigurableMockStrategyFuzz.ReportMode.Stale);
        staleStrategy.setStaleTotalAssets(aliceAssets);
        uint256 staleBobShares = _deposit(staleVault, bob, bobAssets);

        honestStrategy.setMode(ConfigurableMockStrategyFuzz.ReportMode.Honest);
        honestVault.report();
        vm.warp(block.timestamp + HALF_UNLOCK);
        uint256 honestBobShares = _deposit(honestVault, bob, bobAssets);

        assertGt(staleBobShares, honestBobShares);
    }

    function testFuzz_OptimisticVsHonest_OvervalueMintsMoreFeeShares(
        uint256 aliceAssets,
        uint256 profit,
        uint256 overvalueBps
    ) public {
        aliceAssets = bound(aliceAssets, 100 ether, 5_000 ether);
        profit = bound(profit, 100 ether, 5_000 ether);
        overvalueBps = bound(overvalueBps, 100, 10_000);

        (ConfigurableMockStrategyFuzz honestStrategy, IStrategy honestVault) =
            _deployComparisonStrategy("Honest Fee Fuzz Strategy");
        (ConfigurableMockStrategyFuzz optimisticStrategy, IStrategy optimisticVault) =
            _deployComparisonStrategy("Optimistic Fee Fuzz Strategy");

        honestStrategy.setMode(ConfigurableMockStrategyFuzz.ReportMode.Honest);
        optimisticStrategy.setMode(ConfigurableMockStrategyFuzz.ReportMode.Overvalue);
        optimisticStrategy.setBasisPointDelta(overvalueBps);

        _deposit(honestVault, alice, aliceAssets);
        _deposit(optimisticVault, alice, aliceAssets);

        asset.mint(address(honestStrategy), profit);
        asset.mint(address(optimisticStrategy), profit);

        honestVault.report();
        optimisticVault.report();

        uint256 honestFeeShares = honestVault.balanceOf(address(this));
        uint256 optimisticFeeShares = optimisticVault.balanceOf(address(this));

        assertGt(optimisticFeeShares, honestFeeShares);
    }

    function _deployComparisonStrategy(string memory name)
        internal
        returns (ConfigurableMockStrategyFuzz strategy, IStrategy vault)
    {
        strategy = new ConfigurableMockStrategyFuzz(address(asset), name);
        vault = IStrategy(address(strategy));
        _approve(address(vault), alice);
        _approve(address(vault), bob);
    }

    function _approve(address vault, address user) internal {
        vm.prank(user);
        asset.approve(vault, type(uint256).max);
    }

    function _deposit(IStrategy vault, address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        return vault.deposit(assets, user);
    }
}
