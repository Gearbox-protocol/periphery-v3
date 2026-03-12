// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import {IDegenNFT} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IDegenNFT.sol";

interface ISecuritizeDegenNFT is IDegenNFT {
    // ------ //
    // EVENTS //
    // ------ //

    event Mint(address indexed wallet);
    event Burn(address indexed wallet);
    event SetOperatorStatus(address indexed token, address indexed operator, bool approved);
    event SetRegistrar(address indexed token, address indexed registrar);

    // ------ //
    // ERRORS //
    // ------ //

    error CallerIsNotCreditFacadeException(address caller);
    error CallerIsNotFactoryException(address caller);
    error CallerIsNotInstanceOwnerException(address caller);
    error CallerIsNotOperatorException(address token, address caller);
    error RegistrarNotSetForTokenException(address token);
    error UnknownTokenException(address token);
    error UnknownWalletException(address wallet);

    // ------- //
    // GETTERS //
    // ------- //

    function getFactory() external view returns (address);
    function getOperators(address token) external view returns (address[] memory);
    function isOperator(address token, address operator) external view returns (bool);
    function getDSTokens() external view returns (address[] memory);
    function isDSToken(address token) external view returns (bool);
    function getRegistrar(address token) external view returns (address);
    function getRegisteredTokens(address creditAccount) external view returns (address[] memory);

    // ------- //
    // ACTIONS //
    // ------- //

    function mint(address wallet) external;
    function burn(address wallet, uint256) external override;
    function addRegistrar(address registrar) external;
    function setOperatorStatus(address token, address operator, bool approved) external;
    function registerCreditAccount(address creditAccount, address[] calldata tokens) external;
    function registerHelperAccount(address creditAccount, address helperAccount, address token) external;
}
