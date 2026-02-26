// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IStateSerializer} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IStateSerializer.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

interface IOnDemandLiquidityProvider is IVersion, IStateSerializer {
    function allowanceOf(address pool) external view returns (uint256);
    function pullLiquidity(address pool, uint256 amount) external;
}
