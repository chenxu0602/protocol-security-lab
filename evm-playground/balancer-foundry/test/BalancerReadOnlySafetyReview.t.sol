// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./utils/BalancerScaffold.sol";

import "@balancer-labs/v2-interfaces/contracts/pool-weighted/WeightedPoolUserData.sol";
import "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-pool-utils/contracts/test/MockReentrancyPool.sol";
import "@balancer-labs/v2-solidity-utils/contracts/test/TestToken.sol";

contract BalancerReadOnlySafetyReviewTest is BalancerScaffold {
    function testProtectedViewCanBeCalledOutsideVaultContext() external {
        IERC20[] memory reentrancyTokens = _reentrancyTokens();
        MockReentrancyPool pool = _deployReentrancyPool(reentrancyTokens);

        pool.protectedViewFunction();
    }

    function testJoinRevertsWhenPoolReadsProtectedStateInVaultContext() external {
        IERC20[] memory reentrancyTokens = _reentrancyTokens();
        MockReentrancyPool pool = _deployReentrancyPool(reentrancyTokens);
        _initializeReentrancyPool(pool, reentrancyTokens);

        vm.startPrank(alice);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSelector(
                IVault.joinPool.selector,
                pool.getPoolId(),
                alice,
                alice,
                IVault.JoinPoolRequest({
                    assets: _asAssetArray(reentrancyTokens),
                    maxAmountsIn: _zeroAmounts(reentrancyTokens.length),
                    userData: abi.encode(uint256(1)),
                    fromInternalBalance: false
                })
            )
        );
        vm.stopPrank();

        assertFalse(ok, "join should revert in vault context");
    }

    function testSwapRevertsWhenPoolReadsProtectedStateInVaultContext() external {
        IERC20[] memory reentrancyTokens = _reentrancyTokens();
        MockReentrancyPool pool = _deployReentrancyPool(reentrancyTokens);
        _initializeReentrancyPool(pool, reentrancyTokens);

        vm.startPrank(alice);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSelector(
                IVault.swap.selector,
                IVault.SingleSwap({
                    poolId: pool.getPoolId(),
                    kind: IVault.SwapKind.GIVEN_IN,
                    assetIn: IAsset(address(reentrancyTokens[0])),
                    assetOut: IAsset(address(reentrancyTokens[1])),
                    amount: 1e18,
                    userData: ""
                }),
                IVault.FundManagement({
                    sender: alice,
                    fromInternalBalance: false,
                    recipient: payable(alice),
                    toInternalBalance: false
                }),
                0,
                _deadline()
            )
        );
        vm.stopPrank();

        assertFalse(ok, "swap should revert in vault context");
    }

    function testExitRevertsWhenPoolReadsProtectedStateInVaultContext() external {
        IERC20[] memory reentrancyTokens = _reentrancyTokens();
        MockReentrancyPool pool = _deployReentrancyPool(reentrancyTokens);
        uint256 mintedBpt = _initializeReentrancyPool(pool, reentrancyTokens);

        vm.startPrank(alice);
        pool.approve(address(vault), mintedBpt / 2);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSelector(
                IVault.exitPool.selector,
                pool.getPoolId(),
                alice,
                alice,
                IVault.ExitPoolRequest({
                    assets: _asAssetArray(reentrancyTokens),
                    minAmountsOut: _zeroAmounts(reentrancyTokens.length),
                    userData: abi.encode(uint256(1)),
                    toInternalBalance: false
                })
            )
        );
        vm.stopPrank();

        assertFalse(ok, "exit should revert in vault context");
    }

    function _reentrancyTokens() internal returns (IERC20[] memory reentrancyTokens) {
        IERC20 token0 = IERC20(address(new TestToken("DAI", "DAI", 18)));
        IERC20 token1 = IERC20(address(new TestToken("MKR", "MKR", 18)));
        IERC20 token2 = IERC20(address(new TestToken("SNX", "SNX", 18)));

        reentrancyTokens = new IERC20[](3);
        reentrancyTokens[0] = token0;
        reentrancyTokens[1] = token1;
        reentrancyTokens[2] = token2;

        for (uint256 i = 0; i < reentrancyTokens.length; ++i) {
            for (uint256 j = i + 1; j < reentrancyTokens.length; ++j) {
                if (address(reentrancyTokens[j]) < address(reentrancyTokens[i])) {
                    IERC20 tmp = reentrancyTokens[i];
                    reentrancyTokens[i] = reentrancyTokens[j];
                    reentrancyTokens[j] = tmp;
                }
            }
        }

        _mintTokens(reentrancyTokens, alice, DEFAULT_TOKEN_BALANCE);
    }

    function _deployReentrancyPool(IERC20[] memory reentrancyTokens) internal returns (MockReentrancyPool) {
        address[] memory assetManagers = _emptyAssetManagers(reentrancyTokens.length);

        return
            new MockReentrancyPool(
                IVault(address(vault)),
                IVault.PoolSpecialization.GENERAL,
                "Reentrancy Pool",
                "RPT",
                reentrancyTokens,
                assetManagers,
                1e12,
                DEFAULT_PAUSE_WINDOW,
                DEFAULT_BUFFER_PERIOD,
                address(0)
            );
    }

    function _initializeReentrancyPool(MockReentrancyPool pool, IERC20[] memory reentrancyTokens)
        internal
        returns (uint256)
    {
        uint256[] memory amountsIn = _fillExactTokenInputs(reentrancyTokens.length, 100e18);
        uint256 balanceBefore = pool.balanceOf(alice);

        _approveTokens(alice, reentrancyTokens, address(vault), uint256(-1));

        vm.startPrank(alice);
        vault.joinPool(
            pool.getPoolId(),
            alice,
            alice,
            IVault.JoinPoolRequest({
                assets: _asAssetArray(reentrancyTokens),
                maxAmountsIn: amountsIn,
                userData: abi.encode(WeightedPoolUserData.JoinKind.INIT, amountsIn),
                fromInternalBalance: false
            })
        );
        vm.stopPrank();

        return pool.balanceOf(alice) - balanceBefore;
    }
}
