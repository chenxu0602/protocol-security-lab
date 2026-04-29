// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./utils/BalancerScaffold.sol";

contract BalancerLiquidityTemplateTest is BalancerScaffold {
    function testInitJoinSeedsVaultBalancesAndMintsBpt() external {
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = 100e18;
        amountsIn[1] = 100e18;

        uint256[] memory balancesBefore = _vaultPoolBalances();
        uint256 bptOut = _joinInitPool(alice, amountsIn);
        uint256[] memory balancesAfter = _vaultPoolBalances();

        assertTrue(bptOut > 0, "init join should mint BPT");
        assertEq(balancesBefore[0], 0, "token0 pool balance should start at zero");
        assertEq(balancesBefore[1], 0, "token1 pool balance should start at zero");
        assertEq(balancesAfter[0], amountsIn[0], "token0 pool balance mismatch");
        assertEq(balancesAfter[1], amountsIn[1], "token1 pool balance mismatch");
    }

    function testExactBptExitReturnsUnderlyingTokens() external {
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = 150e18;
        amountsIn[1] = 150e18;

        uint256 mintedBpt = _joinInitPool(alice, amountsIn);
        uint256 bptIn = mintedBpt / 4;
        uint256 aliceBptBefore = weightedPool.balanceOf(alice);
        uint256[] memory amountsOut = _exitExactBptInForTokensOut(alice, bptIn);
        uint256 aliceBptAfter = weightedPool.balanceOf(alice);

        assertEq(aliceBptBefore - aliceBptAfter, bptIn, "wrong BPT burned");
        assertTrue(amountsOut[0] > 0, "token0 exit amount should be positive");
        assertTrue(amountsOut[1] > 0, "token1 exit amount should be positive");
    }

    function testSecondLpCanJoinExactTokensIn() external {
        uint256[] memory initAmounts = new uint256[](2);
        initAmounts[0] = 200e18;
        initAmounts[1] = 200e18;
        _joinInitPool(alice, initAmounts);

        uint256[] memory bobJoinAmounts = new uint256[](2);
        bobJoinAmounts[0] = 20e18;
        bobJoinAmounts[1] = 20e18;

        uint256 bptOut = _joinExactTokensInForBptOut(bob, bobJoinAmounts, 0);

        assertTrue(bptOut > 0, "second LP should receive BPT");
    }
}
