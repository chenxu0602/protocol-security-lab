// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./utils/BalancerScaffold.sol";

import "@balancer-labs/v2-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import "@balancer-labs/v2-interfaces/contracts/standalone-utils/IProtocolFeePercentagesProvider.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IAsset.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";

contract BalancerBptReviewTest is BalancerScaffold {
    function testFreshWeightedPoolHasNoPendingProtocolFeeSupply() external {
        uint256[] memory amountsIn = _fillExactTokenInputs(tokens.length, 100e18);
        _joinInitPool(alice, amountsIn);

        assertEq(weightedPool.getActualSupply(), weightedPool.totalSupply(), "fresh pool should not have fee debt");
    }

    function testProportionalJoinKeepsActualSupplyAlignedWithRawSupply() external {
        uint256[] memory initAmounts = _fillExactTokenInputs(tokens.length, 100e18);
        uint256[] memory topUpAmounts = _fillExactTokenInputs(tokens.length, 25e18);

        _joinInitPool(alice, initAmounts);
        uint256[] memory balancesBefore = _vaultPoolBalances();
        uint256 totalSupplyBefore = weightedPool.totalSupply();

        uint256 mintedBpt = _joinExactTokensInForBptOut(bob, topUpAmounts, 0);

        uint256[] memory balancesAfter = _vaultPoolBalances();
        uint256 totalSupplyAfter = weightedPool.totalSupply();

        assertTrue(mintedBpt > 0, "join should mint BPT");
        assertEq(balancesAfter[0] - balancesBefore[0], topUpAmounts[0], "token0 cash delta mismatch");
        assertEq(balancesAfter[1] - balancesBefore[1], topUpAmounts[1], "token1 cash delta mismatch");
        assertEq(totalSupplyAfter - totalSupplyBefore, mintedBpt, "supply delta mismatch");
        assertEq(weightedPool.getActualSupply(), totalSupplyAfter, "unexpected pending fee dilution");
    }

    function testExitBurnsBptAndReducesVaultBalancesConservatively() external {
        uint256[] memory amountsIn = _fillExactTokenInputs(tokens.length, 180e18);
        uint256 mintedBpt = _joinInitPool(alice, amountsIn);
        uint256 bptIn = mintedBpt / 3;

        uint256[] memory balancesBefore = _vaultPoolBalances();
        uint256 totalSupplyBefore = weightedPool.totalSupply();

        uint256[] memory amountsOut = _exitExactBptInForTokensOut(alice, bptIn);

        uint256[] memory balancesAfter = _vaultPoolBalances();
        uint256 totalSupplyAfter = weightedPool.totalSupply();

        assertTrue(amountsOut[0] > 0, "token0 exit amount should be positive");
        assertTrue(amountsOut[1] > 0, "token1 exit amount should be positive");
        assertEq(totalSupplyBefore - totalSupplyAfter, bptIn, "wrong BPT burn amount");
        assertEq(balancesBefore[0] - balancesAfter[0], amountsOut[0], "token0 vault delta mismatch");
        assertEq(balancesBefore[1] - balancesAfter[1], amountsOut[1], "token1 vault delta mismatch");
        assertEq(weightedPool.getActualSupply(), totalSupplyAfter, "unexpected fee debt after exit");
    }

    function testSwapFeesCanMakeActualSupplyExceedRawSupply() external {
        uint256[] memory amountsIn = _fillExactTokenInputs(tokens.length, 100e18);
        _joinInitPool(alice, amountsIn);

        bytes32 providerActionId = protocolFeeProvider.getActionId(
            IProtocolFeePercentagesProvider.setFeeTypePercentage.selector
        );
        authorizer.grantRole(providerActionId, address(this));

        IAuthentication protocolFeesCollector = IAuthentication(address(vault.getProtocolFeesCollector()));
        bytes32 collectorActionId = protocolFeesCollector.getActionId(vault.getProtocolFeesCollector().setSwapFeePercentage.selector);
        authorizer.grantRole(collectorActionId, address(protocolFeeProvider));

        protocolFeeProvider.setFeeTypePercentage(ProtocolFeeType.SWAP, 50e16);
        weightedPool.updateProtocolFeePercentageCache();

        _approvePoolTokens(bob, uint256(-1));

        vm.startPrank(bob);
        vault.swap(
            IVault.SingleSwap({
                poolId: weightedPool.getPoolId(),
                kind: IVault.SwapKind.GIVEN_IN,
                assetIn: IAsset(address(tokens[0])),
                assetOut: IAsset(address(tokens[1])),
                amount: 20e18,
                userData: ""
            }),
            IVault.FundManagement({
                sender: bob,
                fromInternalBalance: false,
                recipient: payable(bob),
                toInternalBalance: false
            }),
            0,
            _deadline()
        );
        vm.stopPrank();

        assertTrue(weightedPool.getActualSupply() > weightedPool.totalSupply(), "pending protocol fee debt not reflected");
    }
}
