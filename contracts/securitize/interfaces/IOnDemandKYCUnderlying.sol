// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IKYCUnderlying} from "./base/IKYCUnderlying.sol";

interface IOnDemandKYCUnderlying is IKYCUnderlying {
    // ------ //
    // EVENTS //
    // ------ //

    event SetUserStatus(address indexed user, bool allowed);
    event SetPool(address indexed pool);

    // ------ //
    // ERRORS //
    // ------ //

    error CallerIsNotMarketConfiguratorAdminException(address caller);
    error InvalidCreditAccountException(address creditAccount);
    error InvalidLiquidityProviderException(address liquidityProvider);
    error InvalidMarketConfiguratorException(address marketConfigurator);
    error InvalidPoolException(address pool);
    error PoolAlreadySetException();
    error PoolNotSetException();
    error UserNotAllowedException(address user);

    // --------- //
    // FUNCTIONS //
    // --------- //

    function getLiquidityProvider() external view returns (address);
    function getMarketConfigurator() external view returns (address);
    function getPool() external view returns (address);
    function setPool(address pool) external;
    function setUserStatus(address user, bool allowed) external;
}
