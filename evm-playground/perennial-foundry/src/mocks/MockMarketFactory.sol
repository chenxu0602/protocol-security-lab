// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { IMarketFactory } from "perennial-v2/packages/core/contracts/interfaces/IMarketFactory.sol";
import { IMarket } from "perennial-v2/packages/core/contracts/interfaces/IMarket.sol";
import { IOracleProvider } from "perennial-v2/packages/core/contracts/interfaces/IOracleProvider.sol";
import { IVerifier } from "perennial-v2/packages/core/contracts/interfaces/IVerifier.sol";
import { IFactory } from "@equilibria/root/attribute/interfaces/IFactory.sol";
import { IInstance } from "@equilibria/root/attribute/interfaces/IInstance.sol";
import { UFixed6 } from "@equilibria/root/number/types/UFixed6.sol";
import { ProtocolParameter } from "perennial-v2/packages/core/contracts/types/ProtocolParameter.sol";
import { OperatorUpdate } from "perennial-v2/packages/core/contracts/types/OperatorUpdate.sol";
import { SignerUpdate } from "perennial-v2/packages/core/contracts/types/SignerUpdate.sol";
import { AccessUpdate } from "perennial-v2/packages/core/contracts/types/AccessUpdate.sol";
import { AccessUpdateBatch } from "perennial-v2/packages/core/contracts/types/AccessUpdateBatch.sol";

contract MockMarketFactory is IMarketFactory {
    address public owner;
    address public pendingOwner;
    address public pauser;
    bool public paused;
    address public implementation;
    IFactory public oracleFactory;
    IVerifier public verifier;

    ProtocolParameter private _parameter;
    mapping(address => bool) private _instances;

    mapping(address => bool) public extensions;
    mapping(address => mapping(address => bool)) public operators;
    mapping(address => mapping(address => bool)) public signers;
    mapping(address => UFixed6) public referralFees;
    mapping(IOracleProvider => IMarket) public markets;

    constructor(IVerifier verifier_) {
        owner = msg.sender;
        pauser = msg.sender;
        verifier = verifier_;
    }

    function parameter() external view returns (ProtocolParameter memory) {
        return _parameter;
    }

    function instances(IInstance instance) external view returns (bool) {
        return _instances[address(instance)];
    }

    function authorization(address account, address sender, address signer, address orderReferrer)
        external
        view
        returns (bool, bool, UFixed6)
    {
        return (
            sender == account || operators[account][sender],
            signer != address(0) && (sender == signer || signers[account][signer]),
            orderReferrer == address(0) ? _parameter.referralFee : referralFees[orderReferrer]
        );
    }

    function initialize() external {}
    function updateParameter(ProtocolParameter memory newParameter) external { _parameter = newParameter; }
    function updateExtension(address extension, bool newEnabled) external { extensions[extension] = newEnabled; }
    function updateOperator(address operator, bool newEnabled) external { operators[msg.sender][operator] = newEnabled; }
    function updateOperatorWithSignature(OperatorUpdate calldata, bytes calldata) external {}
    function updateSigner(address signer, bool newEnabled) external { signers[msg.sender][signer] = newEnabled; }
    function updateSignerWithSignature(SignerUpdate calldata, bytes calldata) external {}
    function updateAccessBatch(AccessUpdate[] calldata, AccessUpdate[] calldata) external {}
    function updateAccessBatchWithSignature(AccessUpdateBatch calldata, bytes calldata) external {}
    function updateReferralFee(address referrer, UFixed6 newReferralFee) external { referralFees[referrer] = newReferralFee; }
    function create(IMarket.MarketDefinition calldata) external pure returns (IMarket) { revert("not implemented"); }

    function updatePendingOwner(address newPendingOwner) external { pendingOwner = newPendingOwner; }
    function acceptOwner() external { owner = msg.sender; pendingOwner = address(0); }
    function updatePauser(address newPauser) external { pauser = newPauser; }
    function pause() external { paused = true; }
    function unpause() external { paused = false; }

    function initializeMarket(IMarket market, IMarket.MarketDefinition calldata definition_) external {
        _instances[address(market)] = true;
        markets[definition_.oracle] = market;
        market.initialize(definition_);
    }
}