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
    address requiredToken;
    uint256 requiredAmount;
    LiquidationOutput[] expectedOutputs;
    MultiCall liquidationCall;
    bool isLiquidatorEligible;
    bool isCreditAccountFrozen;
    string kycProtocol;
    address kycToken;
}

struct RWALiquidatorInfo {
    address gateway;
    address liquidatorAddress;
    bytes32 contractType;
}

library LiquidationLib {
    function append(MultiCall[] memory calls, MultiCall memory call)
        internal
        pure
        returns (MultiCall[] memory newCalls)
    {
        newCalls = new MultiCall[](calls.length + 1);
        for (uint256 i; i < calls.length; ++i) {
            newCalls[i] = calls[i];
        }
        newCalls[calls.length] = call;
    }

    function append(LiquidationOutput[] memory outputs, LiquidationOutput memory output)
        internal
        pure
        returns (LiquidationOutput[] memory newOutputs)
    {
        newOutputs = new LiquidationOutput[](outputs.length + 1);
        for (uint256 i; i < outputs.length; ++i) {
            newOutputs[i] = outputs[i];
        }
        newOutputs[outputs.length] = output;
    }

    function append(address[] memory items, address item) internal pure returns (address[] memory newItems) {
        newItems = new address[](items.length + 1);
        for (uint256 i; i < items.length; ++i) {
            newItems[i] = items[i];
        }
        newItems[items.length] = item;
    }
}
