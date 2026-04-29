// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./utils/BalancerScaffold.sol";

contract BalancerPermissionsTemplateTest is BalancerScaffold {
    function testPoolUsesVaultAuthorizer() external {
        assertEq(address(weightedPool.getAuthorizer()), address(authorizer), "authorizer mismatch");
    }

    function testActionIdsAreStableAcrossPoolsFromSameCreator() external {
        MockWeightedPool otherPool = _deployDefaultWeightedPool();
        bytes4 selector = IControlledPool.setSwapFeePercentage.selector;

        assertEq(weightedPool.getActionId(selector), otherPool.getActionId(selector), "action id mismatch");
    }

    function testUnauthorizedSwapFeeUpdateReverts() external {
        (bool ok, ) = address(weightedPool).call(
            abi.encodeWithSelector(IControlledPool.setSwapFeePercentage.selector, 2e16)
        );

        assertFalse(ok, "unauthorized fee update should revert");
    }

    function testAuthorizedSwapFeeUpdateSucceeds() external {
        uint256 newSwapFee = 2e16;

        _grantSetSwapFeePermission(address(this));
        weightedPool.setSwapFeePercentage(newSwapFee);

        assertEq(weightedPool.getSwapFeePercentage(), newSwapFee, "authorized fee update failed");
    }
}
