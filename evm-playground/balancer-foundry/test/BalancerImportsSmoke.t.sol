// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v2-vault/contracts/Vault.sol";
import "@balancer-labs/v2-pool-weighted/contracts/WeightedPool.sol";

contract BalancerImportsSmokeTest {
    function testBalancerImportsCompile() external pure returns (bool ok) {
        IVault vault;
        vault;

        require(type(Vault).creationCode.length > 0, "vault creation code missing");
        require(type(WeightedPool).creationCode.length > 0, "weighted pool creation code missing");

        return true;
    }
}
