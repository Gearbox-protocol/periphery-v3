// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

struct LossLiquidatorState {
    address addr;
    uint16 lossLiquidatorType;
    uint256 version;
    bytes serialisedData;
}
