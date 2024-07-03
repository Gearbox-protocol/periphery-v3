// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

struct InterestRateModelState {
    address addr;
    uint16 modelType;
    uint256 version;
    bytes serializedParams;
}
