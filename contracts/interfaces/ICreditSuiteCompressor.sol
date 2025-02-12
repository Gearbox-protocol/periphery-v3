// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {CreditSuiteData} from "../types/CreditSuiteData.sol";
import {CreditManagerState} from "../types/CreditManagerState.sol";
import {CreditFacadeState} from "../types/CreditFacadeState.sol";

interface ICreditSuiteCompressor is IVersion {
    function getCreditSuiteData(address creditManager) external view returns (CreditSuiteData memory);

    function getCreditManagerState(address creditManager) external view returns (CreditManagerState memory);

    function getCreditFacadeState(address creditFacade) external view returns (CreditFacadeState memory);
}
