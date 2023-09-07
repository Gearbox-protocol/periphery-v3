import {LinearInterestRateModelV3} from "@gearbox-protocol/core-v3/contracts/pool/LinearInterestRateModelV3.sol";
import {LinearModel} from "./Types.sol";

contract LinearInterestModelHelper {
    function getLIRMData(address _model) internal view returns (LinearModel memory irm) {
        irm.interestModel = _model;

        (irm.U_1, irm.U_2, irm.R_base, irm.R_slope1, irm.R_slope2, irm.R_slope3) =
            LinearInterestRateModelV3(_model).getModelParameters();
    }
}
