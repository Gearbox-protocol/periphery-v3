// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2025.
pragma solidity ^0.8.23;

import {ILiquidationSubcompressor} from "../../../interfaces/ILiquidationSubcompressor.sol";
import {LiquidationData, LiquidationOutput} from "../../../types/LiquidationInfo.sol";
import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

/// @title Stub Securitize liquidation subcompressor.
/// @dev Protocol-specific liquidation preview logic to be filled in later.
contract SecuritizeLiquidationSubcompressor is ILiquidationSubcompressor {
    uint256 public constant version = 3_13;
    bytes32 public constant contractType = "GLOBAL::SECURITIZE_LIQ_SC";

    function getLiquidationData(address, address, address) external pure returns (LiquidationData memory) {
        return LiquidationData({
            requiredUnderlyingAmount: 0,
            expectedOutputs: new LiquidationOutput[](0),
            liquidationCall: MultiCall({target: address(0), callData: ""}),
            isLiquidatorEligible: false,
            kycProtocol: "",
            kycToken: address(0)
        });
    }
}
