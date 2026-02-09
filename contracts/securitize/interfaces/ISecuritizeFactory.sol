// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

interface ISecuritizeFactory is IVersion {
    event AddCreditManager(address indexed creditManager, address indexed whitelister);
    event FreezeCreditAccount(address indexed creditAccount);
    event UnfreezeCreditAccount(address indexed creditAccount);
    event OpenCreditAccount(address indexed creditAccount, address indexed wallet, address indexed investor);
    event SetInvestor(address indexed creditAccount, address indexed oldInvestor, address indexed newInvestor);

    error CreditAccountNotFromFactoryException(address creditAccount);
    error CallerIsNotSecuritizeAdminException(address caller);
    error CreditManagerAlreadyAddedException(address creditManager);
    error CreditManagerNotAddedException(address creditManager);
    error InvalidCreditManagerException(address creditManager);
    error InvalidUnderlyingTokenException(address underlying);
    error ZeroAddressException(address addr);

    function getWhitelister(address creditManager) external view returns (address);
    function addCreditManager(address creditManager, address whitelister) external;

    function isCreditAccountFromFactory(address creditAccount) external view returns (bool);
    function getWallet(address creditAccount) external view returns (address);

    function getInvestor(address creditAccount) external view returns (address);
    function setInvestor(address creditAccount, address investor) external;

    function isFrozen(address creditAccount) external view returns (bool);
    function freeze(address creditAccount) external;
    function unfreeze(address creditAccount) external;

    function getCreditAccounts(address investor) external view returns (address[] memory);
    function openCreditAccount(address creditManager) external returns (address wallet, address creditAccount);
    function precomputeWalletAddress(address creditManager, address investor) external view returns (address);
}
