// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {BuilderFactory, BuilderWallet} from 'panoptic-v2-core/contracts/Builder.sol';
import {Errors} from 'panoptic-v2-core/contracts/libraries/Errors.sol';
import {ERC20S} from 'panoptic-v2-core/test/foundry/testUtils/ERC20S.sol';

contract BuilderWalletTarget {
    uint256 internal _stored;

    function setValue(uint256 newValue) external payable returns (uint256) {
        _stored = newValue;
        return newValue;
    }

    function stored() external view returns (uint256) {
        return _stored;
    }

    function revertWithoutReason() external pure {
        revert();
    }

    function revertWithReason() external pure {
        revert('TARGET_REVERT');
    }
}

contract PanopticBuilderWalletTest is Test {
    BuilderFactory internal factory;
    BuilderWalletTarget internal target;
    ERC20S internal token;

    address internal owner = address(0xA11CE);
    address internal builderAdmin = address(0xB0B);
    address internal receiver = address(0xCAFE);

    function setUp() public {
        vm.prank(owner);
        factory = new BuilderFactory(owner);

        target = new BuilderWalletTarget();
        token = new ERC20S('Builder Token', 'BLD', 18);
    }

    function test_builderFactory_zeroOwnerReverts() external {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new BuilderFactory(address(0));
    }

    function test_predictBuilderWallet_matchesDeployedAddress() external {
        uint48 builderCode = 42;
        address predicted = factory.predictBuilderWallet(builderCode);

        vm.prank(owner);
        address deployed = factory.deployBuilder(builderCode, builderAdmin);

        assertEq(deployed, predicted);
        assertEq(BuilderWallet(payable(deployed)).builderAdmin(), builderAdmin);
        assertEq(BuilderWallet(payable(deployed)).BUILDER_FACTORY(), address(factory));
    }

    function test_deployBuilder_onlyOwner() external {
        vm.expectRevert('NOT_OWNER');
        factory.deployBuilder(1, builderAdmin);
    }

    function test_deployBuilder_duplicateCodeReverts() external {
        vm.startPrank(owner);
        factory.deployBuilder(7, builderAdmin);

        vm.expectRevert(bytes('CREATE2 failed'));
        factory.deployBuilder(7, builderAdmin);
    }

    function test_deployBuilder_zeroAdminReverts() external {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.deployBuilder(8, address(0));
    }

    function test_builderWallet_initIsSingleShot() external {
        BuilderWallet wallet = _deployWallet(100);

        vm.expectRevert(Errors.AlreadyInitialized.selector);
        wallet.init(builderAdmin);
    }

    function test_builderWallet_sweep_requiresBuilderAdmin() external {
        BuilderWallet wallet = _deployWallet(101);

        vm.expectRevert(Errors.NotBuilder.selector);
        wallet.sweep(address(token), receiver);
    }

    function test_builderWallet_sweep_transfersEntireBalance() external {
        BuilderWallet wallet = _deployWallet(102);
        token.mint(address(wallet), 15);

        vm.prank(builderAdmin);
        wallet.sweep(address(token), receiver);

        assertEq(token.balanceOf(address(wallet)), 0);
        assertEq(token.balanceOf(receiver), 15);
    }

    function test_builderWallet_sweep_zeroBalanceIsNoOp() external {
        BuilderWallet wallet = _deployWallet(106);

        vm.prank(builderAdmin);
        wallet.sweep(address(token), receiver);

        assertEq(token.balanceOf(address(wallet)), 0);
        assertEq(token.balanceOf(receiver), 0);
    }

    function test_builderWallet_execute_runsCallAsWallet() external {
        BuilderWallet wallet = _deployWallet(103);

        vm.prank(builderAdmin);
        bytes memory result = wallet.execute(
            address(target),
            0,
            abi.encodeCall(BuilderWalletTarget.setValue, (77))
        );

        assertEq(abi.decode(result, (uint256)), 77);
        assertEq(target.stored(), 77);
    }

    function test_builderWallet_execute_bubblesReasonedRevert() external {
        BuilderWallet wallet = _deployWallet(104);

        vm.prank(builderAdmin);
        vm.expectRevert(bytes('TARGET_REVERT'));
        wallet.execute(address(target), 0, abi.encodeCall(BuilderWalletTarget.revertWithReason, ()));
    }

    function test_builderWallet_execute_usesExecuteFailedForEmptyRevert() external {
        BuilderWallet wallet = _deployWallet(105);

        vm.prank(builderAdmin);
        vm.expectRevert(Errors.ExecuteFailed.selector);
        wallet.execute(
            address(target),
            0,
            abi.encodeCall(BuilderWalletTarget.revertWithoutReason, ())
        );
    }

    function test_builderWallet_execute_requiresBuilderAdmin() external {
        BuilderWallet wallet = _deployWallet(107);

        vm.expectRevert(Errors.NotBuilder.selector);
        wallet.execute(address(target), 0, abi.encodeCall(BuilderWalletTarget.setValue, (1)));
    }

    function _deployWallet(uint48 builderCode) internal returns (BuilderWallet wallet) {
        vm.prank(owner);
        wallet = BuilderWallet(payable(factory.deployBuilder(builderCode, builderAdmin)));
    }
}
