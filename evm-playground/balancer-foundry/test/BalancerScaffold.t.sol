// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./utils/BalancerScaffold.sol";

contract BalancerScaffoldTest is BalancerScaffold {
    function testScaffoldDeploysVaultAndWeightedPool() external {
        bytes32 poolId = weightedPool.getPoolId();
        (address registeredPool, IVault.PoolSpecialization specialization) = vault.getPool(poolId);

        assertTrue(poolId != bytes32(0), "pool id should be initialized");
        assertEq(address(weightedPool.getVault()), address(vault), "pool vault mismatch");
        assertEq(registeredPool, address(weightedPool), "vault registry mismatch");
        assertEq(uint256(specialization), uint256(IVault.PoolSpecialization.TWO_TOKEN), "unexpected specialization");
    }

    function testScaffoldExposesDefaultPoolConfig() external {
        uint256[] memory normalizedWeights = weightedPool.getNormalizedWeights();

        assertEq(normalizedWeights.length, 2, "unexpected token count");
        assertEq(normalizedWeights[0], 50e16, "wrong token0 weight");
        assertEq(normalizedWeights[1], 50e16, "wrong token1 weight");
        assertEq(weightedPool.getSwapFeePercentage(), DEFAULT_SWAP_FEE_PERCENTAGE, "wrong swap fee");
    }

    function testScaffoldCanGrantPoolAdminAction() external {
        uint256 newSwapFeePercentage = 2e16;

        _grantSetSwapFeePermission(address(this));
        weightedPool.setSwapFeePercentage(newSwapFeePercentage);

        assertEq(weightedPool.getSwapFeePercentage(), newSwapFeePercentage, "swap fee update failed");
    }
}
