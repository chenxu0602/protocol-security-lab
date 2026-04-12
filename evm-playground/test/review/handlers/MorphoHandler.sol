// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IMorpho,
    Id,
    MarketParams,
    Market,
    Position
} from "../../../src/review/interfaces/IMorpho.sol";

contract MorphoHandler is Test {

    IMorpho public immutable morpho;
    IERC20 public immutable loanToken;
    IERC20 public immutable collateralToken;

    MarketParams public marketParams;


    address public supplier1;
    address public borrower1;
    address public borrower2;
    address public liquidator;

    uint256 public constant MAX_SUPPLY = 1_000_000e18;
    uint256 public constant MAX_COLLATERAL = 1_000_000e18;
    uint256 public constant MAX_BORROW_TRY = 500_000e18;
    uint256 public constant MIN_WARP = 1 hours;
    uint256 public constant MAX_WARP = 30 days;

    uint256 public successfulSupplies;
    uint256 public successfulCollateralSupplies;
    uint256 public successfulBorrows;
    uint256 public successfulRepays;
    uint256 public successfulLiquidations;
    uint256 public totalWarps;

    address public lastLiquidationTarget;
    uint256 public lastLiquidationAttemptAmount;
    bool    public lastLiquidationSucceeded;
    uint256 public lastLiquidationTargetBorrowSharesBefore;
    uint256 public lastLiquidationTargetCollateralBefore;

    bool public lastActionSucceeded;

    constructor(
        IMorpho _morpho,
        IERC20 _loanToken,
        IERC20 _collateralToken,
        MarketParams memory _marketParams,
        address _supplier1,
        address _borrower1,
        address _borrower2,
        address _liquidator
    ) {
        morpho = _morpho;
        loanToken = _loanToken;
        collateralToken = _collateralToken;
        marketParams = _marketParams;

        supplier1 = _supplier1;
        borrower1 = _borrower1;
        borrower2 = _borrower2;
        liquidator = _liquidator;
    }

    /*//////////////////////////////////////////////////////////////
                            ACTOR HELPERS
    //////////////////////////////////////////////////////////////*/

    function _borrowerFromSeed(uint256 actorSeed) internal view returns (address) {
        return actorSeed % 2 == 0 ? borrower1 : borrower2;
    }

    function actors() external view returns (address, address, address, address) {
        return (supplier1, borrower1, borrower2, liquidator);
    }


    /*//////////////////////////////////////////////////////////////
                           TOKEN HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fundLoanToken(address to, uint256 amount) internal {
        deal(address(loanToken), to, loanToken.balanceOf(to) + amount);
    }

    function _fundCollateralToken(address to, uint256 amount) internal {
        deal(address(collateralToken), to, collateralToken.balanceOf(to) + amount);
    }

    function _boundNonZero(uint256 x, uint256 max) internal pure returns (uint256) {
        return bound(x, 1, max);
    }

    /*//////////////////////////////////////////////////////////////
                              ACTIONS
    //////////////////////////////////////////////////////////////*/

    function supply(uint256 amountSeed) external {
        uint256 amount = _boundNonZero(amountSeed, MAX_SUPPLY);
        address actor = supplier1;

        _fundLoanToken(actor, amount);

        vm.startPrank(actor);
        loanToken.approve(address(morpho), amount);

        try morpho.supply(marketParams, amount, 0, actor, hex"") {
            successfulSupplies++;
            lastActionSucceeded = true;
        } catch {
            lastActionSucceeded = false;
        }

        vm.stopPrank();
    }

    function supplyCollateral(uint256 actorSeed, uint256 amountSeed) external {
        uint256 amount = _boundNonZero(amountSeed, MAX_COLLATERAL);
        address actor = _borrowerFromSeed(actorSeed);

        _fundCollateralToken(actor, amount);

        vm.startPrank(actor);
        collateralToken.approve(address(morpho), amount);

        try morpho.supplyCollateral(marketParams, amount, actor, hex"") {
            successfulCollateralSupplies++;
            lastActionSucceeded = true;
        } catch {
            lastActionSucceeded = false;
        }

        vm.stopPrank();
    }

    function borrow(uint256 actorSeed, uint256 amountSeed) external {
        uint256 amount = _boundNonZero(amountSeed, MAX_BORROW_TRY);
        address actor = _borrowerFromSeed(actorSeed);

        vm.startPrank(actor);

        try morpho.borrow(marketParams, amount, 0, actor, actor) {
            successfulBorrows++;
            lastActionSucceeded = true;
        } catch {
            lastActionSucceeded = false;    
        }

        vm.stopPrank();
    }

    function repay(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _borrowerFromSeed(actorSeed);

        uint256 amount = _boundNonZero(amountSeed, MAX_BORROW_TRY);

        _fundLoanToken(actor, amount);

        vm.startPrank(actor);
        loanToken.approve(address(morpho), amount);

        try morpho.repay(marketParams, amount, 0, actor, hex"") {
            successfulRepays++;
            lastActionSucceeded = true;
        } catch {
            lastActionSucceeded = false;
        }

        vm.stopPrank();
    }

    function liquidate(uint256 targetSeed, uint256 amountSeed) external {
        address target = _borrowerFromSeed(targetSeed);
        uint256 amount = _boundNonZero(amountSeed, MAX_BORROW_TRY);

        Position memory p = morpho.position(id(), target);

        lastLiquidationTarget = target;
        lastLiquidationAttemptAmount = amount;
        lastLiquidationSucceeded = false;

        lastLiquidationTargetBorrowSharesBefore = p.borrowShares;
        lastLiquidationTargetCollateralBefore = p.collateral;

        _fundLoanToken(liquidator, amount);

        vm.startPrank(liquidator);
        loanToken.approve(address(morpho), amount);

        try morpho.liquidate(marketParams, target, amount, 0, hex"") {
            successfulLiquidations++;
            lastActionSucceeded = true;
            lastLiquidationSucceeded = true;
        } catch {
            lastActionSucceeded = false;
        }

        vm.stopPrank();
    }

    function warp(uint256 timeSeed) external {
        uint256 dt = bound(timeSeed, MIN_WARP, MAX_WARP);
        vm.warp(block.timestamp + dt);
        totalWarps++;
        lastActionSucceeded = true;
    }


    /*//////////////////////////////////////////////////////////////
                             READ HELPERS
    //////////////////////////////////////////////////////////////*/

    function getPosition(address user) external view returns (uint256 suppliedShares, uint256 borrowedShares, uint256 collateral) {
        Position memory p = morpho.position(id(), user);
        suppliedShares = p.supplyShares;
        borrowedShares = p.borrowShares;
        collateral = p.collateral;
    }

    function id() public view returns (Id) {
        return Id.wrap(keccak256(abi.encode(marketParams)));
    }

    function marketTotals() external view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares) {
        Market memory m = morpho.market(id());
        totalSupplyAssets = m.totalSupplyAssets;
        totalSupplyShares = m.totalSupplyShares;
        totalBorrowAssets = m.totalBorrowAssets;
        totalBorrowShares = m.totalBorrowShares;
    }

    function borrowerAddress(uint256 actorSeed) external view returns (address) {
        return _borrowerFromSeed(actorSeed);
    }
}