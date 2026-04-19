// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { MockProxyFactory } from "@ctf-exchange-v2/src/test/dev/mocks/MockProxyFactory.sol";
import { MockSafeFactory } from "@ctf-exchange-v2/src/test/dev/mocks/MockSafeFactory.sol";
import {
    ExchangeInitParams,
    Order,
    Side,
    SignatureType,
    ORDER_TYPEHASH
} from "@ctf-exchange-v2/src/exchange/libraries/Structs.sol";
import { CTFExchange } from "@ctf-exchange-v2/src/exchange/CTFExchange.sol";
import { IConditionalTokens } from "@ctf-exchange-v2/src/adapters/interfaces/IConditionalTokens.sol";

library PolymarketArtifactDeployer {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant CONDITIONAL_TOKENS_ARTIFACT =
        "lib/polymarket/ctf-exchange-v2/artifacts/ConditionalTokens.json";
    string internal constant NEG_RISK_ADAPTER_ARTIFACT =
        "lib/polymarket/ctf-exchange-v2/artifacts/NegRiskAdapter.json";

    function deployConditionalTokens() internal returns (address deployed) {
        deployed = deployCode(CONDITIONAL_TOKENS_ARTIFACT, "");
        VM.label(deployed, "ConditionalTokens");
    }

    function deployNegRiskAdapter(address ctf, address collateral, address vault) internal returns (address deployed) {
        deployed = deployCode(NEG_RISK_ADAPTER_ARTIFACT, abi.encode(ctf, collateral, vault));
        VM.label(deployed, "NegRiskAdapter");
    }

    function deployCode(string memory artifactPath, bytes memory constructorArgs)
        internal
        returns (address deployed)
    {
        bytes memory creationCode = abi.encodePacked(VM.getCode(artifactPath), constructorArgs);
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "artifact deploy failed");
    }
}

abstract contract PolymarketAuditBase is Test {
    address internal admin = address(1);
    uint256 internal bobPK = 0xB0B;
    uint256 internal carlaPK = 0xCA414;
    uint256 internal dylanPK = 0xD14A4;

    address internal bob;
    address internal carla;
    address internal dylan;
    address internal feeReceiver = address(9);

    MockProxyFactory internal proxyFactory;
    MockSafeFactory internal safeFactory;

    function _setUpActors() internal {
        bob = vm.addr(bobPK);
        carla = vm.addr(carlaPK);
        dylan = vm.addr(dylanPK);

        vm.label(admin, "admin");
        vm.label(bob, "bob");
        vm.label(carla, "carla");
        vm.label(dylan, "dylan");
        vm.label(feeReceiver, "feeReceiver");
    }

    function _deployConditionalTokens() internal returns (IConditionalTokens) {
        return IConditionalTokens(PolymarketArtifactDeployer.deployConditionalTokens());
    }

    function _deployExchange(
        address collateral,
        address ctf,
        address ctfCollateral,
        address outcomeTokenFactory
    ) internal returns (CTFExchange exchange) {
        proxyFactory = new MockProxyFactory();
        safeFactory = new MockSafeFactory();

        vm.startPrank(admin);
        exchange = new CTFExchange(
            ExchangeInitParams({
                admin: admin,
                collateral: collateral,
                ctf: ctf,
                ctfCollateral: ctfCollateral,
                outcomeTokenFactory: outcomeTokenFactory,
                proxyFactory: address(proxyFactory),
                safeFactory: address(safeFactory),
                feeReceiver: feeReceiver
            })
        );
        exchange.addOperator(bob);
        exchange.addOperator(carla);
        exchange.addOperator(dylan);
        vm.stopPrank();
    }

    function _prepareCondition(IConditionalTokens ctf, address oracle, bytes32 questionId)
        internal
        returns (bytes32)
    {
        ctf.prepareCondition(oracle, questionId, 2);
        return ctf.getConditionId(oracle, questionId, 2);
    }

    function _positionId(IConditionalTokens ctf, address collateral, bytes32 conditionId, uint256 indexSet)
        internal
        view
        returns (uint256)
    {
        return ctf.getPositionId(collateral, ctf.getCollectionId(bytes32(0), conditionId, indexSet));
    }

    function _createOrder(address maker, uint256 tokenId, uint256 makerAmount, uint256 takerAmount, Side side)
        internal
        pure
        returns (Order memory order)
    {
        order = Order({
            salt: 1,
            maker: maker,
            signer: maker,
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            side: side,
            signatureType: SignatureType.EOA,
            timestamp: 0,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: new bytes(0)
        });
    }

    function _createAndSignOrder(
        CTFExchange exchange,
        uint256 pk,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side
    ) internal returns (Order memory order) {
        order = _createOrder(vm.addr(pk), tokenId, makerAmount, takerAmount, side);
        order.signature = _signMessage(pk, exchange.hashOrder(order));
    }

    function _createAndSign1271Order(
        CTFExchange exchange,
        uint256 signerPk,
        address wallet,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side
    ) internal returns (Order memory order) {
        order = _createOrder(wallet, tokenId, makerAmount, takerAmount, side);
        order.signer = wallet;
        order.signatureType = SignatureType.POLY_1271;
        order.signature = _signMessage(signerPk, exchange.hashOrder(order));
    }

    function _signMessage(uint256 pk, bytes32 digest) internal returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _domainSeparator(address exchangeAddress) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Polymarket CTF Exchange")),
                keccak256(bytes("2")),
                block.chainid,
                exchangeAddress
            )
        );
    }

    function _expectedStructHash(Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.salt,
                order.maker,
                order.signer,
                order.tokenId,
                order.makerAmount,
                order.takerAmount,
                order.side,
                order.signatureType,
                order.timestamp,
                order.metadata,
                order.builder
            )
        );
    }
}
