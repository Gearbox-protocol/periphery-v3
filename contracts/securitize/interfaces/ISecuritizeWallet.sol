// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

interface ISecuritizeWallet {
    error CallerIsNotFactoryException(address caller);
    error ForbiddenCallException();

    function factory() external view returns (address);
    function creditManager() external view returns (address);
    function creditAccount() external view returns (address);

    function multicall(MultiCall[] calldata calls) external;
    function receiveToken(address token, address from, uint256 amount) external;
    function approveToken(address token, address to, uint256 amount) external;
    function sendToken(address token, address to, uint256 amount) external;
}
