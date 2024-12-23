// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {BaseParams} from "./BaseState.sol";

struct CreditFacadeState {
    BaseParams baseParams;
    address creditManager;
    address degenNFT;
    address botList;
    bool expirable;
    uint40 expirationDate;
    uint8 maxDebtPerBlockMultiplier;
    uint256 minDebt;
    uint256 maxDebt;
    uint256 forbiddenTokenMask;
    bool isPaused;
}
