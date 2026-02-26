// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOnDemandLiquidityProvider} from "./base/IOnDemandLiquidityProvider.sol";

interface IMonopolizedOnDemandLP is IOnDemandLiquidityProvider {
    // ----- //
    // TYPES //
    // ----- //

    struct Pool {
        address pool;
        address underlying;
        address token;
    }

    // ------ //
    // EVENTS //
    // ------ //

    event AddPool(address indexed token, address indexed underlying, address indexed pool);

    // ------ //
    // ERRORS //
    // ------ //

    error CallerIsNotDepositorException(address caller);
    error CallerIsNotMarketConfiguratorAdminException(address caller);
    error CallerIsNotUnderlyingException(address caller);
    error InvalidKYCFactoryException(address factory);
    error InvalidMarketConfiguratorException(address marketConfigurator);
    error InvalidPoolException(address pool);
    error InvalidUnderlyingTokenException(address underlying);
    error PoolAlreadyAddedException(address pool);
    error PoolNotAddedException(address pool);
    error TokenAlreadyAddedException(address token);

    // --------- //
    // FUNCTIONS //
    // --------- //

    function getMarketConfigurator() external view returns (address);
    function getDepositor() external view returns (address);
    function getPools() external view returns (Pool[] memory);
    function addPool(address pool) external;
    function claim(address pool) external;
}
