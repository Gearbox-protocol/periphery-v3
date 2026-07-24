// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

struct LiquidationOutput {
    address token;
    uint256 amount;
    bool delayed;
    address redeemerAddress;
    uint256 claimableAt;
}

struct LiquidationData {
    uint256 requiredUnderlyingAmount;
    LiquidationOutput[] expectedOutputs;
    MultiCall liquidationCall;
    bool isLiquidatorEligible;
    string kycProtocol;
    address kycToken;
}
