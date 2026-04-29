// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./utils/BalancerScaffold.sol";

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import "@balancer-labs/v2-pool-weighted/contracts/test/MockWeightedPool.sol";

contract TestAssetManager {
    IVault private immutable _vault;

    constructor(IVault vault) {
        _vault = vault;
    }

    function approveVault(IERC20 token, uint256 amount) external {
        token.approve(address(_vault), amount);
    }

    function manage(IVault.PoolBalanceOp[] memory ops) external {
        _vault.managePoolBalance(ops);
    }
}

contract BalancerAssetManagementReviewTest is BalancerScaffold {
    function testManagedBalanceTransitionsRespectCashManagedIdentity() external {
        TestAssetManager assetManager = new TestAssetManager(IVault(address(vault)));
        address[] memory assetManagers = _emptyAssetManagers(tokens.length);
        assetManagers[0] = address(assetManager);

        MockWeightedPool managedPool = _deployWeightedPool(tokens, weights, assetManagers, DEFAULT_SWAP_FEE_PERCENTAGE);
        bytes32 poolId = managedPool.getPoolId();

        _joinInitPool(managedPool, tokens, alice, _fillExactTokenInputs(tokens.length, 200e18));

        (uint256 cashBefore, uint256 managedBefore, , address configuredManager) = vault.getPoolTokenInfo(poolId, tokens[0]);
        assertEq(configuredManager, address(assetManager), "wrong asset manager");
        assertEq(cashBefore, 200e18, "unexpected initial cash");
        assertEq(managedBefore, 0, "unexpected initial managed");

        IVault.PoolBalanceOp[] memory withdrawOps = new IVault.PoolBalanceOp[](1);
        withdrawOps[0] = IVault.PoolBalanceOp({
            kind: IVault.PoolBalanceOpKind.WITHDRAW,
            poolId: poolId,
            token: tokens[0],
            amount: 40e18
        });
        assetManager.manage(withdrawOps);

        (uint256 cashAfterWithdraw, uint256 managedAfterWithdraw, , ) = vault.getPoolTokenInfo(poolId, tokens[0]);
        assertEq(cashAfterWithdraw, 160e18, "cash should move into managed");
        assertEq(managedAfterWithdraw, 40e18, "managed balance should increase");
        assertEq(cashAfterWithdraw + managedAfterWithdraw, cashBefore + managedBefore, "total should be conserved");
        assertEq(IERC20(address(tokens[0])).balanceOf(address(vault)), 160e18, "vault custody mismatch after withdraw");

        _mintSingleToken(tokens[0], address(assetManager), 15e18);
        assetManager.approveVault(tokens[0], 15e18);

        IVault.PoolBalanceOp[] memory depositOps = new IVault.PoolBalanceOp[](1);
        depositOps[0] = IVault.PoolBalanceOp({
            kind: IVault.PoolBalanceOpKind.DEPOSIT,
            poolId: poolId,
            token: tokens[0],
            amount: 15e18
        });
        assetManager.manage(depositOps);

        (uint256 cashAfterDeposit, uint256 managedAfterDeposit, , ) = vault.getPoolTokenInfo(poolId, tokens[0]);
        assertEq(cashAfterDeposit, 175e18, "cash should increase on deposit");
        assertEq(managedAfterDeposit, 25e18, "managed should decrease on deposit");
        assertEq(cashAfterDeposit + managedAfterDeposit, cashBefore + managedBefore, "deposit should preserve total");

        IVault.PoolBalanceOp[] memory updateOps = new IVault.PoolBalanceOp[](1);
        updateOps[0] = IVault.PoolBalanceOp({
            kind: IVault.PoolBalanceOpKind.UPDATE,
            poolId: poolId,
            token: tokens[0],
            amount: 10e18
        });
        assetManager.manage(updateOps);

        (uint256 cashAfterUpdate, uint256 managedAfterUpdate, , ) = vault.getPoolTokenInfo(poolId, tokens[0]);
        assertEq(cashAfterUpdate, cashAfterDeposit, "update should not change cash");
        assertEq(managedAfterUpdate, 10e18, "managed should be overwritten");
        assertEq(cashAfterUpdate + managedAfterUpdate, 185e18, "update defines the trusted total-balance boundary");
    }

    function testNonManagerCannotMutatePoolManagedBalance() external {
        TestAssetManager assetManager = new TestAssetManager(IVault(address(vault)));
        address[] memory assetManagers = _emptyAssetManagers(tokens.length);
        assetManagers[0] = address(assetManager);

        MockWeightedPool managedPool = _deployWeightedPool(tokens, weights, assetManagers, DEFAULT_SWAP_FEE_PERCENTAGE);
        bytes32 poolId = managedPool.getPoolId();

        _joinInitPool(managedPool, tokens, alice, _fillExactTokenInputs(tokens.length, 100e18));

        IVault.PoolBalanceOp[] memory ops = new IVault.PoolBalanceOp[](1);
        ops[0] = IVault.PoolBalanceOp({
            kind: IVault.PoolBalanceOpKind.WITHDRAW,
            poolId: poolId,
            token: tokens[0],
            amount: 1e18
        });

        vm.startPrank(bob);
        (bool ok, ) = address(vault).call(abi.encodeWithSelector(IVault.managePoolBalance.selector, ops));
        vm.stopPrank();

        assertFalse(ok, "non-manager operation should revert");
    }

    function testSwapCannotSpendManagedBalanceAsIfItWereVaultCash() external {
        TestAssetManager assetManager = new TestAssetManager(IVault(address(vault)));
        address[] memory assetManagers = _emptyAssetManagers(tokens.length);
        assetManagers[0] = address(assetManager);

        MockWeightedPool managedPool = _deployWeightedPool(tokens, weights, assetManagers, DEFAULT_SWAP_FEE_PERCENTAGE);
        bytes32 poolId = managedPool.getPoolId();

        _joinInitPool(managedPool, tokens, alice, _fillExactTokenInputs(tokens.length, 200e18));

        IVault.PoolBalanceOp[] memory withdrawOps = new IVault.PoolBalanceOp[](1);
        withdrawOps[0] = IVault.PoolBalanceOp({
            kind: IVault.PoolBalanceOpKind.WITHDRAW,
            poolId: poolId,
            token: tokens[0],
            amount: 180e18
        });
        assetManager.manage(withdrawOps);

        (uint256 cashBeforeSwap, uint256 managedBeforeSwap, , ) = vault.getPoolTokenInfo(poolId, tokens[0]);
        assertEq(cashBeforeSwap, 20e18, "unexpected remaining cash");
        assertEq(managedBeforeSwap, 180e18, "unexpected managed balance");

        _approvePoolTokens(bob, uint256(-1));

        vm.startPrank(bob);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSelector(
                IVault.swap.selector,
                IVault.SingleSwap({
                    poolId: poolId,
                    kind: IVault.SwapKind.GIVEN_OUT,
                    assetIn: IAsset(address(tokens[1])),
                    assetOut: IAsset(address(tokens[0])),
                    amount: 25e18,
                    userData: ""
                }),
                IVault.FundManagement({
                    sender: bob,
                    fromInternalBalance: false,
                    recipient: payable(bob),
                    toInternalBalance: false
                }),
                type(uint256).max,
                _deadline()
            )
        );
        vm.stopPrank();

        assertFalse(ok, "swap should not be able to pull managed liquidity as cash");

        (uint256 cashAfterSwap, uint256 managedAfterSwap, , ) = vault.getPoolTokenInfo(poolId, tokens[0]);
        assertEq(cashAfterSwap, cashBeforeSwap, "failed swap should not change cash");
        assertEq(managedAfterSwap, managedBeforeSwap, "failed swap should not change managed balance");
    }
}
