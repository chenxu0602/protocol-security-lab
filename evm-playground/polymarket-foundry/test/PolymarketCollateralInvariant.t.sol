// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@solady/src/auth/Ownable.sol";

import { PolymarketAuditBase } from "./helpers/PolymarketAuditBase.sol";
import {
    Collateral,
    CollateralSetup,
    CollateralToken,
    USDC,
    USDCe
} from "@ctf-exchange-v2/src/test/dev/CollateralSetup.sol";
import { CollateralErrors } from "@ctf-exchange-v2/src/collateral/abstract/CollateralErrors.sol";

contract PolymarketCollateralInvariantTest is PolymarketAuditBase {
    Collateral internal collateral;
    USDC internal usdc;
    USDCe internal usdce;
    address internal minter = address(0xBEEF);

    function setUp() public {
        _setUpActors();

        collateral = CollateralSetup._deploy(admin);
        usdc = collateral.usdc;
        usdce = collateral.usdce;

        vm.prank(admin);
        collateral.token.addMinter(minter);
    }

    function test_wrapAndUnwrapPreserveFullBacking() public {
        uint256 amount = 125_000_000;

        usdce.mint(bob, amount);

        vm.startPrank(bob);
        usdce.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdce), bob, amount);
        vm.stopPrank();

        assertEq(collateral.token.totalSupply(), amount);
        assertEq(collateral.token.balanceOf(bob), amount);
        assertEq(usdce.balanceOf(collateral.vault), amount);
        assertEq(_backingBalance(), amount);

        vm.startPrank(bob);
        collateral.token.approve(address(collateral.offramp), amount);
        collateral.offramp.unwrap(address(usdce), bob, amount);
        vm.stopPrank();

        assertEq(collateral.token.totalSupply(), 0);
        assertEq(collateral.token.balanceOf(bob), 0);
        assertEq(usdce.balanceOf(collateral.vault), 0);
        assertEq(_backingBalance(), 0);
    }

    function test_pauseBlocksNewWrapWithoutMovingValue() public {
        uint256 amount = 50_000_000;

        usdce.mint(bob, amount);

        vm.prank(admin);
        collateral.onramp.pause(address(usdce));

        vm.startPrank(bob);
        usdce.approve(address(collateral.onramp), amount);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        collateral.onramp.wrap(address(usdce), bob, amount);
        vm.stopPrank();

        assertEq(usdce.balanceOf(bob), amount);
        assertEq(usdce.balanceOf(collateral.vault), 0);
        assertEq(collateral.token.totalSupply(), 0);
    }

    function test_offrampCannotReleaseUnderlyingWithoutEscrowedBurn() public {
        uint256 amount = 40_000_000;

        usdce.mint(bob, amount);

        vm.startPrank(bob);
        usdce.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdce), bob, amount);
        vm.stopPrank();

        vm.prank(carla);
        vm.expectRevert();
        collateral.offramp.unwrap(address(usdce), carla, amount);

        assertEq(usdce.balanceOf(collateral.vault), amount);
        assertEq(usdce.balanceOf(carla), 0);
        assertEq(collateral.token.balanceOf(bob), amount);
        assertEq(collateral.token.totalSupply(), amount);
    }

    function test_onlyOwnerCanManageMintAndWrapRoles() public {
        vm.prank(carla);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.addMinter(carla);

        vm.prank(carla);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.addWrapper(carla);

        vm.startPrank(admin);
        collateral.token.addMinter(carla);
        collateral.token.addWrapper(dylan);
        vm.stopPrank();

        assertTrue(collateral.token.hasAllRoles(carla, 1 << 0));
        assertTrue(collateral.token.hasAllRoles(dylan, 1 << 1));
    }

    function test_documentedRisk_directMinterMintCreatesUnbackedSupply() public {
        uint256 amount = 77_000_000;

        vm.prank(minter);
        collateral.token.mint(bob, amount);

        assertEq(collateral.token.balanceOf(bob), amount);
        assertEq(collateral.token.totalSupply(), amount);
        assertEq(_backingBalance(), 0);
        assertGt(collateral.token.totalSupply(), _backingBalance());
    }

    function _backingBalance() internal view returns (uint256) {
        return usdc.balanceOf(collateral.vault) + usdce.balanceOf(collateral.vault);
    }
}
