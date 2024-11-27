// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {LinearInterestRateModelV3} from "@gearbox-protocol/core-v3/contracts/pool/LinearInterestRateModelV3.sol";
import {IStateSerializerLegacy} from "../../interfaces/IStateSerializerLegacy.sol";
import {IStateSerializer} from "../../interfaces/IStateSerializer.sol";

contract LinearInterestModelSerializer is IStateSerializerLegacy {
    function serialize(address _model) external view returns (bytes memory) {
        uint256 version = LinearInterestRateModelV3(_model).version();

        if (version != 3_00) {
            return IStateSerializer(_model).serialize();
        }

        (uint16 U_1, uint16 U_2, uint16 R_base, uint16 R_slope1, uint16 R_slope2, uint16 R_slope3) =
            LinearInterestRateModelV3(_model).getModelParameters();

        return (
            abi.encode(
                U_1,
                U_2,
                R_base,
                R_slope1,
                R_slope2,
                R_slope3,
                LinearInterestRateModelV3(_model).isBorrowingMoreU2Forbidden()
            )
        );
    }
}
