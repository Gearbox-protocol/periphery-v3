// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {IRWAFactory} from "./base/IRWAFactory.sol";
import {ISecuritizeDegenNFT} from "./ISecuritizeDegenNFT.sol";

interface ISecuritizeRWAFactory is IRWAFactory {
    // ----- //
    // TYPES //
    // ----- //

    struct OpeningSignature {
        address creditManager;
        address accountOwner;
        uint32 deadline;
        uint32 nonce;
        bytes signature;
    }

    struct OpeningInfo {
        uint32 deadline;
        uint32 nonce;
    }

    // ------ //
    // EVENTS //
    // ------ //

    event ApproveOpening(address indexed accountOwner, address indexed creditManager, uint32 deadline);
    event ConsumeOpening(address indexed accountOwner, address indexed creditManager);
    event RevokeOpening(address indexed accountOwner, address indexed creditManager);
    event SetMinSignaturesRequired(address indexed marketConfigurator, uint16 minSignaturesRequired);

    // ------ //
    // ERRORS //
    // ------ //

    error InvalidCreditManagerException(address creditManager);
    error InvalidUnderlyingTokenException(address underlying);
    error TooManyCreditAccountsException(address investor);
    error ZeroAddressException();

    error NotEnoughSignersException();
    error OpeningParamsMismatchException();
    error CallerIsNotEmergencyAdminException(address caller);
    error CallerIsNotInstanceOwnerException(address caller);
    error CannotOpenException();
    error InvalidSignatureParamsException();
    error IncorrectSignerSortingException();
    error IncorrectNonceException();
    error StaleOpeningException();

    // ------- //
    // GETTERS //
    // ------- //

    function getDegenNFT() external view returns (address);
    function minSignaturesRequired(address marketConfigurator) external view returns (uint16);
    function openingDeadlines(address accountOwner, address creditManager)
        external
        view
        returns (uint32 deadline, uint32 nonce);

    // ------------ //
    // USER ACTIONS //
    // ------------ //

    function precomputeWalletAddress(address creditManager, address investor) external view returns (address);
    function openCreditAccount(
        address creditManager,
        MultiCall[] calldata calls,
        address[] calldata tokensToRegister,
        ISecuritizeDegenNFT.RegisterMessage[] calldata signaturesToCache,
        bytes calldata openingData
    ) external returns (address creditAccount, address wallet);
    function multicall(
        address creditAccount,
        MultiCall[] calldata calls,
        address[] calldata tokensToRegister,
        ISecuritizeDegenNFT.RegisterMessage[] calldata signaturesToCache
    ) external;

    function approveOpening(OpeningSignature[] memory openingSignatures) external;
    function revokeOpening(address accountOwner, address creditManager) external;

    // ------------- //
    // ADMIN ACTIONS //
    // ------------- //

    function setMinSignaturesRequired(address marketConfigurator, uint16 minSignaturesRequired_) external;
}
