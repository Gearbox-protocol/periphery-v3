// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

struct CreditFacadeState {
    address addr;
    uint256 version;
    bytes32 contractType;
    address creditManager;
    address creditConfigurator;
    uint256 minDebt;
    uint256 maxDebt;
    address degenNFT;
    uint256 forbiddenTokenMask;
    address lossLiquidator;
    bool isPaused;
}
