// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {BaseParams} from "./BaseState.sol";

struct CollateralToken {
    address token;
    uint16 liquidationThreshold;
}

struct CreditManagerState {
    BaseParams baseParams;
    string name;
    address accountFactory;
    address underlying;
    address pool;
    address creditFacade;
    address creditConfigurator;
    uint8 maxEnabledTokens;
    CollateralToken[] collateralTokens;
    uint16 feeInterest;
    uint16 feeLiquidation;
    uint16 liquidationDiscount;
    uint16 feeLiquidationExpired;
    uint16 liquidationDiscountExpired;
}
