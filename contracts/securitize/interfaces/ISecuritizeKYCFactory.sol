// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {IKYCFactory} from "./base/IKYCFactory.sol";

interface ISecuritizeKYCFactory is IKYCFactory {
    // ------ //
    // EVENTS //
    // ------ //

    event CreateWallet(address indexed creditAccount, address indexed wallet, address indexed investor);
    event SetFrozenStatus(address indexed creditAccount, bool frozen);
    event SetInvestor(address indexed creditAccount, address indexed oldInvestor, address indexed newInvestor);
    event SetRegistrar(address indexed token, address indexed registrar);

    // ------ //
    // ERRORS //
    // ------ //

    error CallerIsNotInstanceOwnerException(address caller);
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

    function getRegistrar(address token) external view returns (address);
    function getWallet(address creditAccount) external view returns (address);
    function getInvestor(address creditAccount) external view returns (address);
    function isFrozen(address creditAccount) external view returns (bool);
    function getRegisteredTokens(address creditAccount) external view returns (address[] memory);
    function getCreditAccounts(address investor) external view returns (address[] memory);

    // -------------- //
    // USER FUNCTIONS //
    // -------------- //

    function precomputeWalletAddress(address creditManager, address investor) external view returns (address);
    function openCreditAccount(address creditManager, MultiCall[] calldata calls, address[] calldata tokensToRegister)
        external
        returns (address creditAccount, address wallet);
    function multicall(address creditAccount, MultiCall[] calldata calls, address[] calldata tokensToRegister) external;

    // --------------- //
    // ADMIN FUNCTIONS //
    // --------------- //

    function addRegistrar(address registrar) external;
    function setFrozenStatus(address creditAccount, bool frozen) external;
    function setInvestor(address creditAccount, address investor) external;
}
