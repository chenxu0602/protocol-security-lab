// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';

import {PanopticFactoryV4} from 'panoptic-v2-core/contracts/PanopticFactoryV4.sol';
import {PanopticPoolV2} from 'panoptic-v2-core/contracts/PanopticPool.sol';
import {CollateralTrackerV2} from 'panoptic-v2-core/contracts/CollateralTracker.sol';
import {RiskEngine} from 'panoptic-v2-core/contracts/RiskEngine.sol';
import {IRiskEngine} from 'panoptic-v2-core/contracts/interfaces/IRiskEngine.sol';
import {ISemiFungiblePositionManager} from 'panoptic-v2-core/contracts/interfaces/ISemiFungiblePositionManager.sol';
import {SemiFungiblePositionManagerV4} from 'panoptic-v2-core/contracts/SemiFungiblePositionManagerV4.sol';
import {Errors} from 'panoptic-v2-core/contracts/libraries/Errors.sol';
import {Pointer} from 'panoptic-v2-core/contracts/types/Pointer.sol';
import {ERC20S} from 'panoptic-v2-core/test/foundry/testUtils/ERC20S.sol';
import {PoolManager} from 'v4-core/PoolManager.sol';
import {PoolKey} from 'v4-core/types/PoolKey.sol';
import {Currency} from 'v4-core/types/Currency.sol';
import {IHooks} from 'v4-core/interfaces/IHooks.sol';
import {IPoolManager} from 'v4-core/interfaces/IPoolManager.sol';

contract PanopticFactoryBindingsTest is Test {
    PoolManager internal manager;
    SemiFungiblePositionManagerV4 internal sfpm;
    RiskEngine internal riskEngine;
    RiskEngine internal secondRiskEngine;
    PanopticFactoryV4 internal factory;

    ERC20S internal assetA;
    ERC20S internal assetB;
    address internal token0;
    address internal token1;
    PoolKey internal key;

    function setUp() public {
        manager = new PoolManager(address(0));
        sfpm = new SemiFungiblePositionManagerV4(IPoolManager(address(manager)), 10 ** 13, 10 ** 13, 0);
        riskEngine = new RiskEngine(10_000_000, 10_000_000, address(0), address(0));
        secondRiskEngine = new RiskEngine(20_000_000, 20_000_000, address(0), address(0));

        assetA = new ERC20S('Token A', 'TKA', 18);
        assetB = new ERC20S('Token B', 'TKB', 18);

        (token0, token1) = address(assetA) < address(assetB)
            ? (address(assetA), address(assetB))
            : (address(assetB), address(assetA));

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        manager.initialize(key, uint160(1 << 96));

        bytes32[] memory properties;
        uint256[][] memory indices;
        Pointer[][] memory pointers;

        factory = new PanopticFactoryV4(
            sfpm,
            IPoolManager(address(manager)),
            address(new PanopticPoolV2(ISemiFungiblePositionManager(address(sfpm)))),
            address(new CollateralTrackerV2()),
            properties,
            indices,
            pointers
        );
    }

    function test_deployNewPool_bindsCanonicalTokenOrderAndTrackers() external {
        PanopticPoolV2 pool = factory.deployNewPool(key, IRiskEngine(address(riskEngine)), 1);

        assertEq(address(factory.getPanopticPool(key, IRiskEngine(address(riskEngine)))), address(pool));
        assertEq(address(pool.riskEngine()), address(riskEngine));
        assertEq(pool.poolManager(), address(manager));
        assertEq(pool.tickSpacing(), key.tickSpacing);

        CollateralTrackerV2 ct0 = pool.collateralToken0();
        CollateralTrackerV2 ct1 = pool.collateralToken1();

        assertEq(address(ct0.panopticPool()), address(pool));
        assertEq(address(ct1.panopticPool()), address(pool));
        assertEq(ct0.underlyingToken(), token0);
        assertEq(ct1.underlyingToken(), token1);
        assertEq(ct0.token0(), token0);
        assertEq(ct0.token1(), token1);
        assertEq(ct1.token0(), token0);
        assertEq(ct1.token1(), token1);
        assertTrue(ct0.underlyingIsToken0());
        assertFalse(ct1.underlyingIsToken0());
    }

    function test_deployNewPool_rejectsDuplicateRegistryEntry() external {
        factory.deployNewPool(key, IRiskEngine(address(riskEngine)), 1);

        vm.expectRevert(Errors.AlreadyInitialized.selector);
        factory.deployNewPool(key, IRiskEngine(address(riskEngine)), 2);
    }

    function test_deployNewPool_initializersAreSingleShot() external {
        PanopticPoolV2 pool = factory.deployNewPool(key, IRiskEngine(address(riskEngine)), 1);
        CollateralTrackerV2 ct0 = pool.collateralToken0();
        CollateralTrackerV2 ct1 = pool.collateralToken1();

        vm.expectRevert(Errors.AlreadyInitialized.selector);
        pool.initialize();

        vm.expectRevert(Errors.AlreadyInitialized.selector);
        ct0.initialize();

        vm.expectRevert(Errors.AlreadyInitialized.selector);
        ct1.initialize();
    }

    function test_deployNewPool_allowsDistinctRegistryEntriesForDifferentRiskEngines() external {
        PanopticPoolV2 pool0 = factory.deployNewPool(key, IRiskEngine(address(riskEngine)), 1);
        PanopticPoolV2 pool1 = factory.deployNewPool(key, IRiskEngine(address(secondRiskEngine)), 1);

        assertTrue(address(pool0) != address(pool1));
        assertEq(address(factory.getPanopticPool(key, IRiskEngine(address(riskEngine)))), address(pool0));
        assertEq(
            address(factory.getPanopticPool(key, IRiskEngine(address(secondRiskEngine)))),
            address(pool1)
        );
    }

    function test_deployNewPool_zeroRiskEngineReverts() external {
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.deployNewPool(key, IRiskEngine(address(0)), 1);
    }

    function test_minePoolAddress_isDeterministicForSameInputs() external view {
        (uint96 salt0, uint256 rarity0) = factory.minePoolAddress(
            address(this),
            key,
            address(riskEngine),
            11,
            7,
            99
        );
        (uint96 salt1, uint256 rarity1) = factory.minePoolAddress(
            address(this),
            key,
            address(riskEngine),
            11,
            7,
            99
        );

        assertEq(salt0, salt1);
        assertEq(rarity0, rarity1);
    }

    function test_minePoolAddress_returnsSaltWithinSearchWindow() external view {
        uint96 startSalt = 25;
        uint256 loops = 5;

        (uint96 bestSalt, ) = factory.minePoolAddress(
            address(this),
            key,
            address(riskEngine),
            startSalt,
            loops,
            0
        );

        assertEq(bestSalt, startSalt);
    }

    function test_minePoolAddress_withZeroLoopsReturnsDefaultTuple() external view {
        (uint96 bestSalt, uint256 rarity) = factory.minePoolAddress(
            address(this),
            key,
            address(riskEngine),
            123,
            0,
            0
        );

        assertEq(bestSalt, 0);
        assertEq(rarity, 0);
    }
}
