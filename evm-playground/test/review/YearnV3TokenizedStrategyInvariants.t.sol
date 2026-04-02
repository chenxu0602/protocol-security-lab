// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {BaseStrategy} from "../../src/review/BaseStrategy.sol";
import {TokenizedStrategy} from "../../src/review/TokenizedStrategy.sol";
import {MockERC20} from "../../src/review/MockERC20.sol";
import {IStrategy} from "../../src/review/interfaces/IStrategy.sol";

contract MockFactoryInvariant {
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

contract AddressSpacerInvariant {}

contract HonestHarnessStrategyInvariant is BaseStrategy {
    constructor(address _asset, string memory _name) BaseStrategy(_asset, _name) {}

    function _deployFunds(uint256) internal override {}

    function _freeFunds(uint256) internal override {}

    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        return asset.balanceOf(address(this));
    }
}

contract ConfigurableMockStrategyInvariant is BaseStrategy {
    constructor(address _asset, string memory _name) BaseStrategy(_asset, _name) {}

    function _deployFunds(uint256) internal override {}

    function _freeFunds(uint256) internal override {}

    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        return asset.balanceOf(address(this));
    }
}

contract NoOpHandler is Test {
    uint256 public calls;

    function poke() external {
        calls++;
    }
}

contract TimeWarpHandler is Test {
    function advance(uint256 step) external {
        step = bound(step, 1, 1 days);
        vm.warp(block.timestamp + step);
    }
}

contract YearnV3TokenizedStrategyHonestNoOpInvariantTest is StdInvariant, Test {
    address internal constant TOKENIZED_STRATEGY_ADDRESS =
        0x2e234DAe75C793f67A35089C9d99245E1C58470b;
    uint256 internal constant STARTING_BALANCE = 1_000 ether;

    MockERC20 internal asset;
    MockFactoryInvariant internal factory;
    HonestHarnessStrategyInvariant internal honestStrategy;
    IStrategy internal honestVault;
    NoOpHandler internal handler;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_700_000_000);

        asset = new MockERC20("Mock Asset", "MA", 18);
        new AddressSpacerInvariant();
        factory = new MockFactoryInvariant();
        factory.setProtocolFeeConfig(0, address(0));

        TokenizedStrategy implementation = new TokenizedStrategy(address(factory));
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(implementation).code);

        honestStrategy = new HonestHarnessStrategyInvariant(address(asset), "Invariant Honest Strategy");
        honestVault = IStrategy(address(honestStrategy));

        asset.mint(alice, STARTING_BALANCE);
        asset.mint(bob, STARTING_BALANCE);

        _approve(address(honestVault), alice);
        _approve(address(honestVault), bob);

        _deposit(honestVault, alice, 100 ether);
        _deposit(honestVault, bob, 100 ether);

        handler = new NoOpHandler();
        targetContract(address(handler));
    }

    function invariant_HonestNoOpReportDoesNotShiftClaims() public {
        uint256 aliceClaimBefore = _claim(honestVault, alice);
        uint256 bobClaimBefore = _claim(honestVault, bob);
        uint256 supplyBefore = honestVault.totalSupply();

        honestVault.report();

        assertEq(_claim(honestVault, alice), aliceClaimBefore);
        assertEq(_claim(honestVault, bob), bobClaimBefore);
        assertEq(honestVault.totalSupply(), supplyBefore);
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

contract YearnV3TokenizedStrategyUnlockInvariantTest is StdInvariant, Test {
    address internal constant TOKENIZED_STRATEGY_ADDRESS =
        0x2e234DAe75C793f67A35089C9d99245E1C58470b;
    uint256 internal constant STARTING_BALANCE = 1_000 ether;

    MockERC20 internal asset;
    MockFactoryInvariant internal factory;
    ConfigurableMockStrategyInvariant internal strategy;
    IStrategy internal vault;
    TimeWarpHandler internal handler;

    address internal alice = makeAddr("alice");

    uint256 internal initialLockedShares;
    uint256 internal lastUnlockedShares;

    function setUp() public {
        vm.warp(1_700_000_000);

        asset = new MockERC20("Mock Asset", "MA", 18);
        new AddressSpacerInvariant();
        factory = new MockFactoryInvariant();
        factory.setProtocolFeeConfig(0, address(0));

        TokenizedStrategy implementation = new TokenizedStrategy(address(factory));
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(implementation).code);

        strategy = new ConfigurableMockStrategyInvariant(address(asset), "Invariant Unlock Strategy");
        vault = IStrategy(address(strategy));

        asset.mint(alice, STARTING_BALANCE);
        _approve(address(vault), alice);

        _deposit(vault, alice, 100 ether);
        asset.mint(address(strategy), 100 ether);
        vault.report();

        initialLockedShares = vault.balanceOf(address(strategy));
        lastUnlockedShares = vault.unlockedShares();

        handler = new TimeWarpHandler();
        targetContract(address(handler));
    }

    function invariant_UnlockMonotonicity() public {
        uint256 currentUnlockedShares = vault.unlockedShares();

        assertGe(currentUnlockedShares, lastUnlockedShares);
        assertLe(currentUnlockedShares, initialLockedShares);

        lastUnlockedShares = currentUnlockedShares;
    }

    function _approve(address vaultAddress, address user) internal {
        vm.prank(user);
        asset.approve(vaultAddress, type(uint256).max);
    }

    function _deposit(IStrategy vaultAddress, address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        return vaultAddress.deposit(assets, user);
    }
}
