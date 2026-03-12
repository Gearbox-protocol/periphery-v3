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

    // ------ //
    // ERRORS //
    // ------ //

    error InvalidCreditManagerException(address creditManager);
    error InvalidUnderlyingTokenException(address underlying);
    error ZeroAddressException();

    // ------- //
    // GETTERS //
    // ------- //

    function getDegenNFT() external view returns (address);

    // ------------ //
    // USER ACTIONS //
    // ------------ //

    function precomputeWalletAddress(address creditManager, address investor) external view returns (address);
    function openCreditAccount(address creditManager, MultiCall[] calldata calls, address[] calldata tokensToRegister)
        external
        returns (address creditAccount, address wallet);
    function multicall(address creditAccount, MultiCall[] calldata calls, address[] calldata tokensToRegister) external;

    // ------------- //
    // ADMIN ACTIONS //
    // ------------- //

    function setFrozenStatus(address creditAccount, bool frozen) external;
    function setInvestor(address creditAccount, address investor) external;
}
