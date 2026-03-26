// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import "../../src/review/MockERC20.sol";
import "../../src/review/MockERC4626Vault.sol";

contract ERC4626Test is Test {
    MockERC20 asset;
    MockERC4626Vault vault;

    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        asset = new MockERC20("Mock Asset", "MA", 18);
        vault = new MockERC4626Vault(asset, "Vault Share", "vMA");

        asset.mint(user1, 1_000 ether);
        asset.mint(user2, 1_000 ether);

        vm.prank(user1);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(user2);
        asset.approve(address(vault), type(uint256).max);
    }

    function testFirstDepositMintsOneToOneShares() public {
        vm.prank(user1);
        uint256 shares = vault.deposit(100 ether, user1);

        assertEq(shares, 100 ether);
        assertEq(vault.balanceOf(user1), 100 ether);
        assertEq(vault.totalSupply(), 100 ether);
        assertEq(vault.totalAssets(), 100 ether);
    }

    function testPreviewDepositMatchesDepositForSimpleCase() public {
        uint256 preview = vault.previewDeposit(100 ether);

        vm.prank(user1);
        uint256 shares = vault.deposit(100 ether, user1);

        assertEq(shares, preview);
    }

    function testPreviewRedeemMatchesRedeemForSimpleCase() public {
        vm.prank(user1);
        vault.deposit(100 ether, user1);

        uint256 previewAssets = vault.previewRedeem(40 ether);

        vm.prank(user1);
        uint256 assetsOut = vault.redeem(40 ether, user1, user1);

        assertEq(assetsOut, previewAssets);
    }

    function testDonationChangesSharePrice() public {
        vm.prank(user1);
        vault.deposit(100 ether, user1);

        vm.prank(user2);
        asset.transfer(address(vault), 100 ether);

        assertEq(vault.totalAssets(), 200 ether);
        assertEq(vault.totalSupply(), 100 ether);

        // 1 share now claims 2 assets
        assertEq(vault.convertToAssets(1 ether), 2 ether);
    }

    function testSecondDepositorGetsFewerSharesAfterDonation() public {
        vm.prank(user1);
        vault.deposit(100 ether, user1);

        vm.prank(user2);
        asset.transfer(address(vault), 100 ether);

        uint256 preview = vault.previewDeposit(100 ether);

        vm.prank(user2);
        uint256 shares = vault.deposit(100 ether, user2);

        assertEq(shares, preview);
        assertEq(shares, 50 ether);
    }

    function testDepositRevertsWhenPreviewIsZero() public {
        vm.prank(user1);
        vault.deposit(1 ether, user1);

        // Donate enough assets to make 1 wei deposit mint 0 shares under rounding down
        vm.prank(user2);
        asset.transfer(address(vault), 1000 ether);

        vm.prank(user1);
        vm.expectRevert("ZERO_SHARES");
        vault.deposit(1, user1);
    }
}