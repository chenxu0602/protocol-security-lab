// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./utils/BalancerScaffold.sol";

import "@balancer-labs/v2-interfaces/contracts/vault/IAsset.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import "@balancer-labs/v2-pool-weighted/contracts/test/MockWeightedPool.sol";
import "@balancer-labs/v2-solidity-utils/contracts/test/TestToken.sol";

contract BalancerBatchSwapReviewTest is BalancerScaffold {
    function testBatchSwapMultihopConservesNetAssetDeltas() external {
        IERC20 tokenC = IERC20(address(new TestToken("Token C", "TKC", 18)));
        _mintSingleToken(tokenC, alice, DEFAULT_TOKEN_BALANCE);

        IERC20[] memory pool0Tokens = _orderedPair(tokens[0], tokens[1]);
        IERC20[] memory pool1Tokens = _orderedPair(tokens[1], tokenC);
        uint256[] memory poolWeights = _orderedWeights();

        MockWeightedPool pool0 = _deployWeightedPool(
            pool0Tokens,
            poolWeights,
            _emptyAssetManagers(pool0Tokens.length),
            DEFAULT_SWAP_FEE_PERCENTAGE
        );
        MockWeightedPool pool1 = _deployWeightedPool(
            pool1Tokens,
            poolWeights,
            _emptyAssetManagers(pool1Tokens.length),
            DEFAULT_SWAP_FEE_PERCENTAGE
        );

        _joinInitPool(pool0, pool0Tokens, alice, _fillExactTokenInputs(pool0Tokens.length, 200e18));
        _joinInitPool(pool1, pool1Tokens, alice, _fillExactTokenInputs(pool1Tokens.length, 200e18));

        IERC20[] memory assets = new IERC20[](3);
        assets[0] = tokens[0];
        assets[1] = tokens[1];
        assets[2] = tokenC;

        uint256[] memory userBalancesBefore = _balancesOf(assets, alice);
        uint256[] memory vaultBalancesBefore = _vaultTokenBalances(assets);

        IVault.BatchSwapStep[] memory steps = new IVault.BatchSwapStep[](2);
        steps[0] = IVault.BatchSwapStep({
            poolId: pool0.getPoolId(),
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: 10e18,
            userData: ""
        });
        steps[1] = IVault.BatchSwapStep({
            poolId: pool1.getPoolId(),
            assetInIndex: 1,
            assetOutIndex: 2,
            amount: 0,
            userData: ""
        });

        int256[] memory limits = new int256[](3);
        limits[0] = 1_000e18;
        limits[1] = 1_000e18;
        limits[2] = 1_000e18;

        vm.startPrank(alice);
        int256[] memory assetDeltas = vault.batchSwap(
            IVault.SwapKind.GIVEN_IN,
            steps,
            _asAssetArray(assets),
            IVault.FundManagement({
                sender: alice,
                fromInternalBalance: false,
                recipient: payable(alice),
                toInternalBalance: false
            }),
            limits,
            _deadline()
        );
        vm.stopPrank();

        uint256[] memory userBalancesAfter = _balancesOf(assets, alice);
        uint256[] memory vaultBalancesAfter = _vaultTokenBalances(assets);

        require(assetDeltas[0] > 0, "token0 should be net in");
        require(assetDeltas[1] == 0, "middle asset should net to zero");
        require(assetDeltas[2] < 0, "token2 should be net out");

        assertEq(userBalancesBefore[0] - userBalancesAfter[0], uint256(assetDeltas[0]), "user token0 delta mismatch");
        assertEq(userBalancesAfter[2] - userBalancesBefore[2], uint256(-assetDeltas[2]), "user token2 delta mismatch");
        assertEq(userBalancesAfter[1], userBalancesBefore[1], "user token1 should net out");

        assertEq(vaultBalancesAfter[0] - vaultBalancesBefore[0], uint256(assetDeltas[0]), "vault token0 delta mismatch");
        assertEq(vaultBalancesAfter[1], vaultBalancesBefore[1], "vault token1 should net out");
        assertEq(vaultBalancesBefore[2] - vaultBalancesAfter[2], uint256(-assetDeltas[2]), "vault token2 delta mismatch");
    }

    function testBatchSwapRejectsMalformedMultihopSentinel() external {
        IERC20 tokenC = IERC20(address(new TestToken("Token C", "TKC", 18)));
        _mintSingleToken(tokenC, alice, DEFAULT_TOKEN_BALANCE);

        IERC20[] memory pool0Tokens = _orderedPair(tokens[0], tokens[1]);
        IERC20[] memory pool1Tokens = _orderedPair(tokens[0], tokenC);
        uint256[] memory poolWeights = _orderedWeights();

        MockWeightedPool pool0 = _deployWeightedPool(
            pool0Tokens,
            poolWeights,
            _emptyAssetManagers(pool0Tokens.length),
            DEFAULT_SWAP_FEE_PERCENTAGE
        );
        MockWeightedPool pool1 = _deployWeightedPool(
            pool1Tokens,
            poolWeights,
            _emptyAssetManagers(pool1Tokens.length),
            DEFAULT_SWAP_FEE_PERCENTAGE
        );

        _joinInitPool(pool0, pool0Tokens, alice, _fillExactTokenInputs(pool0Tokens.length, 150e18));
        _joinInitPool(pool1, pool1Tokens, alice, _fillExactTokenInputs(pool1Tokens.length, 150e18));

        IERC20[] memory assets = new IERC20[](3);
        assets[0] = tokens[0];
        assets[1] = tokens[1];
        assets[2] = tokenC;

        IVault.BatchSwapStep[] memory steps = new IVault.BatchSwapStep[](2);
        steps[0] = IVault.BatchSwapStep({
            poolId: pool0.getPoolId(),
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: 5e18,
            userData: ""
        });
        steps[1] = IVault.BatchSwapStep({
            poolId: pool1.getPoolId(),
            assetInIndex: 0,
            assetOutIndex: 2,
            amount: 0,
            userData: ""
        });

        int256[] memory limits = new int256[](3);
        limits[0] = 1_000e18;
        limits[1] = 1_000e18;
        limits[2] = 1_000e18;

        vm.startPrank(alice);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSelector(
                IVault.batchSwap.selector,
                IVault.SwapKind.GIVEN_IN,
                steps,
                _asAssetArray(assets),
                IVault.FundManagement({
                    sender: alice,
                    fromInternalBalance: false,
                    recipient: payable(alice),
                    toInternalBalance: false
                }),
                limits,
                _deadline()
            )
        );
        vm.stopPrank();

        assertFalse(ok, "malformed multihop should revert");
    }

    function testBatchSwapGivenOutMultihopConservesNetAssetDeltas() external {
        IERC20 tokenC = IERC20(address(new TestToken("Token C", "TKC", 18)));
        _mintSingleToken(tokenC, alice, DEFAULT_TOKEN_BALANCE);

        IERC20[] memory pool0Tokens = _orderedPair(tokens[0], tokens[1]);
        IERC20[] memory pool1Tokens = _orderedPair(tokens[0], tokenC);
        uint256[] memory poolWeights = _orderedWeights();

        MockWeightedPool pool0 = _deployWeightedPool(
            pool0Tokens,
            poolWeights,
            _emptyAssetManagers(pool0Tokens.length),
            DEFAULT_SWAP_FEE_PERCENTAGE
        );
        MockWeightedPool pool1 = _deployWeightedPool(
            pool1Tokens,
            poolWeights,
            _emptyAssetManagers(pool1Tokens.length),
            DEFAULT_SWAP_FEE_PERCENTAGE
        );

        _joinInitPool(pool0, pool0Tokens, alice, _fillExactTokenInputs(pool0Tokens.length, 200e18));
        _joinInitPool(pool1, pool1Tokens, alice, _fillExactTokenInputs(pool1Tokens.length, 200e18));

        IERC20[] memory assets = new IERC20[](3);
        assets[0] = tokens[0];
        assets[1] = tokens[1];
        assets[2] = tokenC;

        uint256[] memory userBalancesBefore = _balancesOf(assets, alice);
        uint256[] memory vaultBalancesBefore = _vaultTokenBalances(assets);

        IVault.BatchSwapStep[] memory steps = new IVault.BatchSwapStep[](2);
        steps[0] = IVault.BatchSwapStep({
            poolId: pool0.getPoolId(),
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: 10e18,
            userData: ""
        });
        steps[1] = IVault.BatchSwapStep({
            poolId: pool1.getPoolId(),
            assetInIndex: 2,
            assetOutIndex: 0,
            amount: 0,
            userData: ""
        });

        int256[] memory limits = new int256[](3);
        limits[0] = 1_000e18;
        limits[1] = 1_000e18;
        limits[2] = 1_000e18;

        vm.startPrank(alice);
        int256[] memory assetDeltas = vault.batchSwap(
            IVault.SwapKind.GIVEN_OUT,
            steps,
            _asAssetArray(assets),
            IVault.FundManagement({
                sender: alice,
                fromInternalBalance: false,
                recipient: payable(alice),
                toInternalBalance: false
            }),
            limits,
            _deadline()
        );
        vm.stopPrank();

        uint256[] memory userBalancesAfter = _balancesOf(assets, alice);
        uint256[] memory vaultBalancesAfter = _vaultTokenBalances(assets);

        require(assetDeltas[0] == 0, "middle asset should net to zero");
        require(assetDeltas[1] < 0, "token1 should be net out");
        require(assetDeltas[2] > 0, "token2 should be net in");

        assertEq(userBalancesAfter[0], userBalancesBefore[0], "user token0 should net out");
        assertEq(userBalancesAfter[1] - userBalancesBefore[1], uint256(-assetDeltas[1]), "user token1 delta mismatch");
        assertEq(userBalancesBefore[2] - userBalancesAfter[2], uint256(assetDeltas[2]), "user token2 delta mismatch");

        assertEq(vaultBalancesAfter[0], vaultBalancesBefore[0], "vault token0 should net out");
        assertEq(vaultBalancesBefore[1] - vaultBalancesAfter[1], uint256(-assetDeltas[1]), "vault token1 delta mismatch");
        assertEq(vaultBalancesAfter[2] - vaultBalancesBefore[2], uint256(assetDeltas[2]), "vault token2 delta mismatch");
    }

    function testBatchSwapGivenOutRejectsMalformedMultihopSentinel() external {
        IERC20 tokenC = IERC20(address(new TestToken("Token C", "TKC", 18)));
        _mintSingleToken(tokenC, alice, DEFAULT_TOKEN_BALANCE);

        IERC20[] memory pool0Tokens = _orderedPair(tokens[0], tokens[1]);
        IERC20[] memory pool1Tokens = _orderedPair(tokens[1], tokenC);
        uint256[] memory poolWeights = _orderedWeights();

        MockWeightedPool pool0 = _deployWeightedPool(
            pool0Tokens,
            poolWeights,
            _emptyAssetManagers(pool0Tokens.length),
            DEFAULT_SWAP_FEE_PERCENTAGE
        );
        MockWeightedPool pool1 = _deployWeightedPool(
            pool1Tokens,
            poolWeights,
            _emptyAssetManagers(pool1Tokens.length),
            DEFAULT_SWAP_FEE_PERCENTAGE
        );

        _joinInitPool(pool0, pool0Tokens, alice, _fillExactTokenInputs(pool0Tokens.length, 150e18));
        _joinInitPool(pool1, pool1Tokens, alice, _fillExactTokenInputs(pool1Tokens.length, 150e18));

        IERC20[] memory assets = new IERC20[](3);
        assets[0] = tokens[0];
        assets[1] = tokens[1];
        assets[2] = tokenC;

        IVault.BatchSwapStep[] memory steps = new IVault.BatchSwapStep[](2);
        steps[0] = IVault.BatchSwapStep({
            poolId: pool0.getPoolId(),
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: 10e18,
            userData: ""
        });
        steps[1] = IVault.BatchSwapStep({
            poolId: pool1.getPoolId(),
            assetInIndex: 2,
            assetOutIndex: 1,
            amount: 0,
            userData: ""
        });

        int256[] memory limits = new int256[](3);
        limits[0] = 1_000e18;
        limits[1] = 1_000e18;
        limits[2] = 1_000e18;

        vm.startPrank(alice);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSelector(
                IVault.batchSwap.selector,
                IVault.SwapKind.GIVEN_OUT,
                steps,
                _asAssetArray(assets),
                IVault.FundManagement({
                    sender: alice,
                    fromInternalBalance: false,
                    recipient: payable(alice),
                    toInternalBalance: false
                }),
                limits,
                _deadline()
            )
        );
        vm.stopPrank();

        assertFalse(ok, "malformed GIVEN_OUT multihop should revert");
    }
}
