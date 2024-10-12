// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.10;

import {ContractAdapter} from "../types/MarketData.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

/// @title Adapter compressor 3.1
interface IAdapterCompressor is IVersion {
    function getContractAdapters(address creditManager) external view returns (ContractAdapter[] memory result);
}
