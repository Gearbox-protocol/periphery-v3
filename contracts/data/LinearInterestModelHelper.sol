// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {LinearInterestRateModelV3} from "@gearbox-protocol/core-v3/contracts/pool/LinearInterestRateModelV3.sol";
import {LinearInterestRateModel} from "@gearbox-protocol/core-v2/contracts/pool/LinearInterestRateModel.sol";
import {LinearModel} from "./Types.sol";

contract LinearInterestModelHelper {
    function getLIRMData(address _model) internal view returns (LinearModel memory irm) {
        irm.interestModel = _model;
        irm.version = LinearInterestRateModel(_model).version();

        if (irm.version == 1) {
            (uint256 U_1, uint256 R_base, uint256 R_slope1, uint256 R_slope2) =
                LinearInterestRateModel(_model).getModelParameters();
            irm.U_1 = uint16(U_1);
            irm.R_base = uint16(R_base);
            irm.R_slope1 = uint16(R_slope1);
            irm.R_slope2 = uint16(R_slope2);
        } else {
            (irm.U_1, irm.U_2, irm.R_base, irm.R_slope1, irm.R_slope2, irm.R_slope3) =
                LinearInterestRateModelV3(_model).getModelParameters();
        }
    }
}
