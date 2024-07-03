// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

struct TokenData {
    address addr;
    string symbol;
    string name;
    uint8 decimals;
}

/// 3 sources:
/// "PriceOracleFather"
/// Pools | on the fly in SDK
/// Farming pools | on the fly in SDK
/// subscribe on new token addition event
///
/// POV3 -> POV3.1
///
