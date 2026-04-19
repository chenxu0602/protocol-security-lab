// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";

import { IConditionalTokens } from "polymarket/neg-risk-ctf-adapter/src/interfaces/IConditionalTokens.sol";

contract BatchTestUsd {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        emit Approval(from, msg.sender, allowance[from][msg.sender]);
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract VaultHarness {
    mapping(address => uint256) public admins;

    constructor() {
        admins[msg.sender] = 1;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender] == 1, "NotAdmin");
        _;
    }

    function transferERC1155(address erc1155, address to, uint256 id, uint256 value) external onlyAdmin {
        IConditionalTokens(erc1155).safeTransferFrom(address(this), to, id, value, "");
    }

    function batchTransferERC1155(address erc1155, address to, uint256[] calldata ids, uint256[] calldata values)
        external
        onlyAdmin
    {
        IConditionalTokens(erc1155).safeBatchTransferFrom(address(this), to, ids, values, "");
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}

contract PolymarketVaultBatchInvariantTest is Test {
    string internal constant CONDITIONAL_TOKENS_ARTIFACT =
        "lib/polymarket/ctf-exchange-v2/artifacts/ConditionalTokens.json";

    address internal admin = address(1);
    address internal bob = address(2);

    VaultHarness internal vault;
    BatchTestUsd internal usdc;
    IConditionalTokens internal ctf;
    bytes32 internal conditionId;
    uint256 internal yes;
    uint256 internal no;

    function setUp() public {
        vm.label(admin, "admin");
        vm.label(bob, "bob");

        vm.prank(admin);
        vault = new VaultHarness();

        usdc = new BatchTestUsd();
        ctf = IConditionalTokens(_deployConditionalTokens());

        ctf.prepareCondition(admin, keccak256("vault-batch"), 2);
        conditionId = ctf.getConditionId(admin, keccak256("vault-batch"), 2);
        yes = ctf.getPositionId(address(usdc), ctf.getCollectionId(bytes32(0), conditionId, 1));
        no = ctf.getPositionId(address(usdc), ctf.getCollectionId(bytes32(0), conditionId, 2));
    }

    function test_batchTransferRevertsOnMismatchedArrayLengths() public {
        _depositIntoVault(yes, 50_000_000);

        uint256[] memory ids = new uint256[](2);
        ids[0] = yes;
        ids[1] = no;

        uint256[] memory values = new uint256[](1);
        values[0] = 10_000_000;

        vm.expectRevert();
        vm.prank(admin);
        vault.batchTransferERC1155(address(ctf), bob, ids, values);
    }

    function test_batchTransferWithDuplicateIdsMovesExactSummedAmount() public {
        _depositIntoVault(yes, 90_000_000);

        uint256[] memory ids = new uint256[](2);
        ids[0] = yes;
        ids[1] = yes;

        uint256[] memory values = new uint256[](2);
        values[0] = 20_000_000;
        values[1] = 15_000_000;

        vm.prank(admin);
        vault.batchTransferERC1155(address(ctf), bob, ids, values);

        assertEq(ctf.balanceOf(bob, yes), 35_000_000);
        assertEq(ctf.balanceOf(address(vault), yes), 55_000_000);
    }

    function test_batchTransferWithPermutedIdsTransfersCorrectBasket() public {
        _depositIntoVault(yes, 80_000_000);
        _depositIntoVault(no, 70_000_000);

        uint256[] memory ids = new uint256[](2);
        ids[0] = no;
        ids[1] = yes;

        uint256[] memory values = new uint256[](2);
        values[0] = 25_000_000;
        values[1] = 30_000_000;

        vm.prank(admin);
        vault.batchTransferERC1155(address(ctf), bob, ids, values);

        assertEq(ctf.balanceOf(bob, yes), 30_000_000);
        assertEq(ctf.balanceOf(bob, no), 25_000_000);
        assertEq(ctf.balanceOf(address(vault), yes), 50_000_000);
        assertEq(ctf.balanceOf(address(vault), no), 45_000_000);
    }

    function test_batchTransferDuplicateIdsRevertsIfSplitAmountsExceedBalance() public {
        _depositIntoVault(yes, 10_000_000);

        uint256[] memory ids = new uint256[](2);
        ids[0] = yes;
        ids[1] = yes;

        uint256[] memory values = new uint256[](2);
        values[0] = 6_000_000;
        values[1] = 5_000_000;

        vm.expectRevert();
        vm.prank(admin);
        vault.batchTransferERC1155(address(ctf), bob, ids, values);

        assertEq(ctf.balanceOf(address(vault), yes), 10_000_000);
        assertEq(ctf.balanceOf(bob, yes), 0);
    }

    function _deployConditionalTokens() internal returns (address deployed) {
        bytes memory creationCode = vm.getCode(CONDITIONAL_TOKENS_ARTIFACT);
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "deploy failed");
    }

    function _depositIntoVault(uint256 tokenId, uint256 amount) internal {
        usdc.mint(admin, amount);

        vm.startPrank(admin);
        usdc.approve(address(ctf), amount);
        ctf.splitPosition(address(usdc), bytes32(0), conditionId, _partition(), amount);
        ctf.safeTransferFrom(admin, address(vault), tokenId, amount, "");
        vm.stopPrank();
    }

    function _partition() internal pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
    }
}
