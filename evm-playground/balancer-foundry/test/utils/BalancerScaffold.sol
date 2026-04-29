// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./Assertions.sol";

import "@balancer-labs/v2-interfaces/contracts/pool-weighted/WeightedPoolUserData.sol";
import "@balancer-labs/v2-interfaces/contracts/pool-utils/IControlledPool.sol";
import "@balancer-labs/v2-interfaces/contracts/pool-utils/IRateProvider.sol";
import "@balancer-labs/v2-interfaces/contracts/standalone-utils/IProtocolFeePercentagesProvider.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IAsset.sol";
import "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";

import "@balancer-labs/v2-pool-weighted/contracts/WeightedPool.sol";
import "@balancer-labs/v2-pool-weighted/contracts/test/MockWeightedPool.sol";
import "@balancer-labs/v2-solidity-utils/contracts/test/MockBasicAuthorizer.sol";
import "@balancer-labs/v2-solidity-utils/contracts/test/TestToken.sol";
import "@balancer-labs/v2-standalone-utils/contracts/ProtocolFeePercentagesProvider.sol";
import "@balancer-labs/v2-standalone-utils/contracts/test/TestWETH.sol";
import "@balancer-labs/v2-vault/contracts/Vault.sol";

abstract contract BalancerScaffold is Assertions {
    address internal constant DELEGATE_OWNER = 0xBA1BA1ba1BA1bA1bA1Ba1BA1ba1BA1bA1ba1ba1B;

    uint256 internal constant DEFAULT_TOKEN_BALANCE = 1_000_000e18;
    uint256 internal constant DEFAULT_SWAP_FEE_PERCENTAGE = 1e16;
    uint256 internal constant MAX_PROTOCOL_FEE_PERCENTAGE = 10e16;
    uint256 internal constant DEFAULT_PAUSE_WINDOW = 90 days;
    uint256 internal constant DEFAULT_BUFFER_PERIOD = 30 days;

    address internal admin;
    address payable internal alice;
    address payable internal bob;
    address payable internal lp;

    MockBasicAuthorizer internal authorizer;
    TestWETH internal weth;
    Vault internal vault;
    ProtocolFeePercentagesProvider internal protocolFeeProvider;
    MockWeightedPool internal weightedPool;

    IERC20[] internal tokens;
    uint256[] internal weights;

    function setUp() public virtual {
        authorizer = new MockBasicAuthorizer();
        admin = authorizer.getRoleMember(authorizer.DEFAULT_ADMIN_ROLE(), 0);

        weth = new TestWETH();
        vault = new Vault(authorizer, weth, DEFAULT_PAUSE_WINDOW, DEFAULT_BUFFER_PERIOD);
        protocolFeeProvider = new ProtocolFeePercentagesProvider(
            IVault(address(vault)),
            MAX_PROTOCOL_FEE_PERCENTAGE,
            MAX_PROTOCOL_FEE_PERCENTAGE
        );

        _setUpDefaultTokens();
        _setUpDefaultUsers();
        weightedPool = _deployDefaultWeightedPool();
    }

    function _setUpDefaultTokens() internal {
        IERC20 tokenA = IERC20(address(new TestToken("Token A", "TKA", 18)));
        IERC20 tokenB = IERC20(address(new TestToken("Token B", "TKB", 18)));

        tokens = new IERC20[](2);
        weights = new uint256[](2);

        if (address(tokenA) < address(tokenB)) {
            tokens[0] = tokenA;
            tokens[1] = tokenB;
        } else {
            tokens[0] = tokenB;
            tokens[1] = tokenA;
        }

        weights[0] = 50e16;
        weights[1] = 50e16;
    }

    function _setUpDefaultUsers() internal {
        alice = _createUser("alice");
        bob = _createUser("bob");
        lp = _createUser("lp");

        _mintPoolTokens(alice, DEFAULT_TOKEN_BALANCE);
        _mintPoolTokens(bob, DEFAULT_TOKEN_BALANCE);
        _mintPoolTokens(lp, DEFAULT_TOKEN_BALANCE);
    }

    function _deployDefaultWeightedPool() internal returns (MockWeightedPool) {
        address[] memory assetManagers = new address[](tokens.length);
        return _deployWeightedPool(tokens, weights, assetManagers, DEFAULT_SWAP_FEE_PERCENTAGE);
    }

    function _deployWeightedPool(
        IERC20[] memory poolTokens,
        uint256[] memory normalizedWeights,
        address[] memory assetManagers,
        uint256 swapFeePercentage
    ) internal returns (MockWeightedPool) {
        return
            new MockWeightedPool(
                WeightedPool.NewPoolParams({
                    name: "Balancer Audit Pool",
                    symbol: "BAP",
                    tokens: poolTokens,
                    normalizedWeights: normalizedWeights,
                    rateProviders: new IRateProvider[](poolTokens.length),
                    assetManagers: assetManagers,
                    swapFeePercentage: swapFeePercentage
                }),
                IVault(address(vault)),
                IProtocolFeePercentagesProvider(address(protocolFeeProvider)),
                DEFAULT_PAUSE_WINDOW,
                DEFAULT_BUFFER_PERIOD,
                DELEGATE_OWNER
            );
    }

    function _createUser(string memory label) internal returns (address payable user) {
        uint256 privateKey = uint256(keccak256(abi.encodePacked(label)));
        user = payable(vm.addr(privateKey));
        vm.label(user, label);
        vm.deal(user, 100 ether);
    }

    function _mintPoolTokens(address recipient, uint256 amount) internal {
        _mintTokens(tokens, recipient, amount);
    }

    function _mintTokens(
        IERC20[] memory erc20s,
        address recipient,
        uint256 amount
    ) internal {
        for (uint256 i = 0; i < erc20s.length; ++i) {
            TestToken(address(erc20s[i])).mint(recipient, amount);
        }
    }

    function _mintSingleToken(
        IERC20 token,
        address recipient,
        uint256 amount
    ) internal {
        TestToken(address(token)).mint(recipient, amount);
    }

    function _balancesOf(address account) internal view returns (uint256[] memory balances) {
        return _balancesOf(tokens, account);
    }

    function _balancesOf(IERC20[] memory erc20s, address account) internal view returns (uint256[] memory balances) {
        balances = new uint256[](erc20s.length);
        for (uint256 i = 0; i < erc20s.length; ++i) {
            balances[i] = IERC20(address(erc20s[i])).balanceOf(account);
        }
    }

    function _vaultTokenBalances(IERC20[] memory erc20s) internal view returns (uint256[] memory balances) {
        balances = new uint256[](erc20s.length);
        for (uint256 i = 0; i < erc20s.length; ++i) {
            balances[i] = IERC20(address(erc20s[i])).balanceOf(address(vault));
        }
    }

    function _poolAddressToAssets(address[] memory tokenAddresses) internal pure returns (IAsset[] memory assets) {
        assets = new IAsset[](tokenAddresses.length);
        for (uint256 i = 0; i < tokenAddresses.length; ++i) {
            assets[i] = IAsset(tokenAddresses[i]);
        }
    }

    function _orderedPair(IERC20 tokenA, IERC20 tokenB) internal pure returns (IERC20[] memory orderedTokens) {
        orderedTokens = new IERC20[](2);

        if (address(tokenA) < address(tokenB)) {
            orderedTokens[0] = tokenA;
            orderedTokens[1] = tokenB;
        } else {
            orderedTokens[0] = tokenB;
            orderedTokens[1] = tokenA;
        }
    }

    function _orderedWeights() internal pure returns (uint256[] memory normalizedWeights) {
        normalizedWeights = new uint256[](2);
        normalizedWeights[0] = 50e16;
        normalizedWeights[1] = 50e16;
    }

    function _emptyAssetManagers(uint256 length) internal pure returns (address[] memory assetManagers) {
        assetManagers = new address[](length);
    }

    function _fillExactTokenInputs(uint256 length, uint256 amount) internal pure returns (uint256[] memory amountsIn) {
        amountsIn = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            amountsIn[i] = amount;
        }
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 days;
    }

    function _grantSetSwapFeePermission(address account) internal {
        bytes32 actionId = weightedPool.getActionId(IControlledPool.setSwapFeePercentage.selector);
        authorizer.grantRole(actionId, account);
    }

    function _approvePoolTokens(address owner, uint256 amount) internal {
        _approveTokens(owner, tokens, address(vault), amount);
    }

    function _approveTokens(
        address owner,
        IERC20[] memory erc20s,
        address spender,
        uint256 amount
    ) internal {
        vm.startPrank(owner);
        for (uint256 i = 0; i < erc20s.length; ++i) {
            IERC20(address(erc20s[i])).approve(spender, amount);
        }
        vm.stopPrank();
    }

    function _joinInitPool(address sender, uint256[] memory amountsIn) internal returns (uint256 bptOut) {
        return _joinInitPool(weightedPool, tokens, sender, amountsIn);
    }

    function _joinInitPool(
        MockWeightedPool pool,
        IERC20[] memory poolTokens,
        address sender,
        uint256[] memory amountsIn
    ) internal returns (uint256 bptOut) {
        uint256 balanceBefore = pool.balanceOf(sender);

        _approveTokens(sender, poolTokens, address(vault), uint256(-1));

        vm.startPrank(sender);
        vault.joinPool(
            pool.getPoolId(),
            sender,
            sender,
            IVault.JoinPoolRequest({
                assets: _asAssetArray(poolTokens),
                maxAmountsIn: amountsIn,
                userData: abi.encode(WeightedPoolUserData.JoinKind.INIT, amountsIn),
                fromInternalBalance: false
            })
        );
        vm.stopPrank();

        return pool.balanceOf(sender) - balanceBefore;
    }

    function _joinExactTokensInForBptOut(
        address sender,
        uint256[] memory amountsIn,
        uint256 minBptOut
    ) internal returns (uint256 bptOut) {
        return _joinExactTokensInForBptOut(weightedPool, tokens, sender, amountsIn, minBptOut);
    }

    function _joinExactTokensInForBptOut(
        MockWeightedPool pool,
        IERC20[] memory poolTokens,
        address sender,
        uint256[] memory amountsIn,
        uint256 minBptOut
    ) internal returns (uint256 bptOut) {
        uint256 balanceBefore = pool.balanceOf(sender);

        _approveTokens(sender, poolTokens, address(vault), uint256(-1));

        vm.startPrank(sender);
        vault.joinPool(
            pool.getPoolId(),
            sender,
            sender,
            IVault.JoinPoolRequest({
                assets: _asAssetArray(poolTokens),
                maxAmountsIn: amountsIn,
                userData: abi.encode(WeightedPoolUserData.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, amountsIn, minBptOut),
                fromInternalBalance: false
            })
        );
        vm.stopPrank();

        return pool.balanceOf(sender) - balanceBefore;
    }

    function _exitExactBptInForTokensOut(address sender, uint256 bptAmountIn) internal returns (uint256[] memory) {
        return _exitExactBptInForTokensOut(weightedPool, tokens, sender, bptAmountIn);
    }

    function _exitExactBptInForTokensOut(
        MockWeightedPool pool,
        IERC20[] memory poolTokens,
        address sender,
        uint256 bptAmountIn
    ) internal returns (uint256[] memory) {
        uint256[] memory balancesBefore = _balancesOf(poolTokens, sender);

        vm.startPrank(sender);
        pool.approve(address(vault), bptAmountIn);
        vault.exitPool(
            pool.getPoolId(),
            sender,
            payable(sender),
            IVault.ExitPoolRequest({
                assets: _asAssetArray(poolTokens),
                minAmountsOut: _zeroAmounts(poolTokens.length),
                userData: abi.encode(WeightedPoolUserData.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT, bptAmountIn),
                toInternalBalance: false
            })
        );
        vm.stopPrank();

        uint256[] memory balancesAfter = _balancesOf(poolTokens, sender);
        uint256[] memory amountsOut = new uint256[](balancesAfter.length);

        for (uint256 i = 0; i < balancesAfter.length; ++i) {
            amountsOut[i] = balancesAfter[i] - balancesBefore[i];
        }

        return amountsOut;
    }

    function _vaultPoolBalances() internal view returns (uint256[] memory balances) {
        return _vaultPoolBalances(weightedPool.getPoolId());
    }

    function _vaultPoolBalances(bytes32 poolId) internal view returns (uint256[] memory balances) {
        (, balances, ) = vault.getPoolTokens(poolId);
    }

    function _asAssetArray(IERC20[] memory erc20s) internal pure returns (IAsset[] memory assets) {
        assets = new IAsset[](erc20s.length);
        for (uint256 i = 0; i < erc20s.length; ++i) {
            assets[i] = IAsset(address(erc20s[i]));
        }
    }

    function _zeroAmounts(uint256 length) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](length);
    }
}
