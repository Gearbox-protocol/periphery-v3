// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

interface ISecuritizeWallet {
    error CallerIsNotFactoryException(address caller);
    error CallerIsNotInvestorException(address caller, address creditAccount);
    error ForbiddenCallException();

    function factory() external view returns (address);
    function underlying() external view returns (address);
    function creditManager() external view returns (address);
    function creditAccount() external view returns (address);
    function multicall(MultiCall[] calldata calls) external;
    function rescueToken(address token, address to) external;
}
