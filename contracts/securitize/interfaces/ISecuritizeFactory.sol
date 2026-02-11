// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

interface ISecuritizeFactory is IVersion {
    // ------ //
    // EVENTS //
    // ------ //

    event CreateWallet(address indexed creditAccount, address indexed wallet, address indexed investor);
    event SetAdmin(address indexed admin);
    event SetFrozenStatus(address indexed creditAccount, bool frozen);
    event SetInvestor(address indexed creditAccount, address indexed oldInvestor, address indexed newInvestor);
    event SetRegistrar(address indexed token, address indexed registrar);

    // ------ //
    // ERRORS //
    // ------ //

    error CallerIsNotAdminException(address caller);
    error CallerIsNotInvestorException(address caller, address creditAccount);
    error FrozenCreditAccountException(address creditAccount);
    error InvalidCreditManagerException(address creditManager);
    error InvalidUnderlyingTokenException(address underlying);
    error UnknownCreditAccountException(address creditAccount);
    error WalletCallExecutionFailedException(uint256 index, bytes reason);
    error RegistrarNotSetForTokenException(address token);
    error ZeroAddressException();

    // ------- //
    // GETTERS //
    // ------- //

    function getAdmin() external view returns (address);
    function getRegistrar(address token) external view returns (address);
    function isCreditAccountFromFactory(address creditAccount) external view returns (bool);
    function getWallet(address creditAccount) external view returns (address);
    function getInvestor(address creditAccount) external view returns (address);
    function isFrozen(address creditAccount) external view returns (bool);
    function getCreditAccounts(address investor) external view returns (address[] memory);

    // -------------- //
    // USER FUNCTIONS //
    // -------------- //

    function precomputeWalletAddress(address creditManager, address investor) external view returns (address);
    function openCreditAccount(address creditManager, address[] calldata tokensToRegister, bytes[] calldata walletCalls)
        external
        returns (address creditAccount, address wallet);
    function registerTokens(address creditAccount, address[] calldata tokens) external;
    function executeWalletCalls(address creditAccount, bytes[] calldata calls) external;

    // --------------- //
    // ADMIN FUNCTIONS //
    // --------------- //

    function setAdmin(address admin) external;
    function addRegistrar(address registrar) external;
    function setFrozenStatus(address creditAccount, bool frozen) external;
    function setInvestor(address creditAccount, address investor) external;
}
