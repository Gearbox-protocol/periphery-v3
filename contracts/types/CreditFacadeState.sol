// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {BaseParams} from "./BaseState.sol";

struct CreditFacadeState {
    BaseParams baseParams;
    uint256 maxQuotaMultiplier;
    address creditManager;
    address treasury;
    bool expirable;
    address degenNFT;
    uint40 expirationDate;
    uint8 maxDebtPerBlockMultiplier;
    address botList;
    uint256 minDebt;
    uint256 maxDebt;
    uint256 forbiddenTokenMask;
    address lossLiquidator;
    bool isPaused;
}
