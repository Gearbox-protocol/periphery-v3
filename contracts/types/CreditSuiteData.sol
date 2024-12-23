// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {CreditManagerState} from "./CreditManagerState.sol";
import {CreditFacadeState} from "./CreditFacadeState.sol";
import {BaseState, BaseParams} from "./BaseState.sol";

struct AdapterState {
    BaseParams baseParams;
    address targetContract;
}

struct CreditSuiteData {
    CreditFacadeState creditFacade;
    CreditManagerState creditManager;
    BaseState creditConfigurator;
    AdapterState[] adapters;
}
