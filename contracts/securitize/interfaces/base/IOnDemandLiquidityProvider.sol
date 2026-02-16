// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

interface IOnDemandLiquidityProvider is IVersion {
    function allowanceOf(address token, address pool) external view returns (uint256);
    function onBorrow(address token, address pool, address creditAccount, uint256 amount) external;
    function onRepay(address token, address pool, address creditAccount, uint256 amount) external;
}
