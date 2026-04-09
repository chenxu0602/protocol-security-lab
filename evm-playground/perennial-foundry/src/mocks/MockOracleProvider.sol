// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { IOracleProvider } from "perennial-v2/packages/core/contracts/interfaces/IOracleProvider.sol";
import { IMarket } from "perennial-v2/packages/core/contracts/interfaces/IMarket.sol";
import { OracleVersion } from "perennial-v2/packages/core/contracts/types/OracleVersion.sol";
import { OracleReceipt } from "perennial-v2/packages/core/contracts/types/OracleReceipt.sol";

contract MockOracleProvider is IOracleProvider {
    OracleVersion public latestVersion;
    uint256 public currentVersion;
    OracleReceipt public receipt;
    mapping(uint256 => OracleVersion) public versions;
    mapping(uint256 => OracleReceipt) public receipts;

    function setStatus(OracleVersion memory version_, uint256 currentVersion_) external {
        latestVersion = version_;
        currentVersion = currentVersion_;
        versions[version_.timestamp] = version_;
        receipts[version_.timestamp] = receipt;
    }

    function setReceipt(OracleReceipt memory receipt_) external {
        receipt = receipt_;
    }

    function request(IMarket, address) external {}

    function status() external view returns (OracleVersion memory, uint256) {
        return (latestVersion, currentVersion);
    }

    function latest() external view returns (OracleVersion memory) {
        return latestVersion;
    }

    function current() external view returns (uint256) {
        return currentVersion;
    }

    function at(uint256 timestamp) external view returns (OracleVersion memory, OracleReceipt memory) {
        OracleVersion memory version = versions[timestamp];
        OracleReceipt memory versionReceipt = receipts[timestamp];

        if (version.timestamp == 0 && latestVersion.timestamp == timestamp) {
            version = latestVersion;
            versionReceipt = receipt;
        }

        if (version.timestamp == 0) {
            version = latestVersion;
            versionReceipt = receipt;
        }

        return (version, versionReceipt);
    }
}
