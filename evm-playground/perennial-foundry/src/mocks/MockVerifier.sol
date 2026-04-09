// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { IVerifier } from "perennial-v2/packages/core/contracts/interfaces/IVerifier.sol";
import { Common } from "@equilibria/root/verifier/types/Common.sol";
import { GroupCancellation } from "@equilibria/root/verifier/types/GroupCancellation.sol";
import { Fill } from "perennial-v2/packages/core/contracts/types/Fill.sol";
import { Intent } from "perennial-v2/packages/core/contracts/types/Intent.sol";
import { Take } from "perennial-v2/packages/core/contracts/types/Take.sol";
import { OperatorUpdate } from "perennial-v2/packages/core/contracts/types/OperatorUpdate.sol";
import { SignerUpdate } from "perennial-v2/packages/core/contracts/types/SignerUpdate.sol";
import { AccessUpdateBatch } from "perennial-v2/packages/core/contracts/types/AccessUpdateBatch.sol";

contract MockVerifier is IVerifier {
    mapping(address => mapping(uint256 => bool)) public nonces;
    mapping(address => mapping(uint256 => bool)) public groups;

    function verifyCommon(Common calldata, bytes calldata) external {}
    function verifyGroupCancellation(GroupCancellation calldata, bytes calldata) external {}

    function cancelNonce(uint256 nonce) external {
        nonces[msg.sender][nonce] = true;
    }

    function cancelNonceWithSignature(Common calldata common, bytes calldata) external {
        nonces[common.account][common.nonce] = true;
    }

    function cancelGroup(uint256 group) external {
        groups[msg.sender][group] = true;
    }

    function cancelGroupWithSignature(GroupCancellation calldata groupCancellation, bytes calldata) external {
        groups[groupCancellation.common.account][groupCancellation.group] = true;
    }

    function verifyFill(Fill calldata, bytes calldata) external {}
    function verifyIntent(Intent calldata, bytes calldata) external {}
    function verifyTake(Take calldata, bytes calldata) external {}
    function verifyOperatorUpdate(OperatorUpdate calldata, bytes calldata) external {}
    function verifySignerUpdate(SignerUpdate calldata, bytes calldata) external {}
    function verifyAccessUpdateBatch(AccessUpdateBatch calldata, bytes calldata) external {}
}
