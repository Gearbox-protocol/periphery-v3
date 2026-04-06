// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {BaseParams} from "../types/BaseState.sol";
import {TokenData} from "./ITokenCompressor.sol";

interface IKYCCompressor is IVersion {
    // ----- //
    // TYPES //
    // ----- //

    struct KYCUnderlyingData {
        BaseParams baseParams;
        address asset;
        address factory;
        bytes extraDetails;
    }

    struct KYCFactoryData {
        BaseParams baseParams;
        TokenData[] tokens;
        bytes extraDetails;
    }

    struct KYCCreditAccountData {
        address creditAccount;
        address wallet;
        bool frozen;
        bytes extraDetails;
    }

    struct KYCInvestorData {
        KYCCreditAccountData[] creditAccounts;
        bytes extraDetails;
    }

    // ------ //
    // ERRORS //
    // ------ //

    error CallerIsNotInstanceOwnerException(address caller);
    error InvalidDomainException(bytes32 domain);
    error InvalidKYCFactoryException(address factory);
    error InvalidMarketConfiguratorException(address marketConfigurator);

    // ------- //
    // GETTERS //
    // ------- //

    function subcompressors(bytes32 domain, bytes32 postfix) external view returns (address);
    function getKYCMarketsData(address[] calldata configurators, address[] calldata factories)
        external
        view
        returns (KYCUnderlyingData[] memory, KYCFactoryData[] memory);
    function getKYCInvestorData(address investor, address[] calldata factories)
        external
        view
        returns (KYCInvestorData[] memory);

    // ---------------------- //
    // INSTANCE OWNER ACTIONS //
    // ---------------------- //

    function setSubcompressor(address subcompressor) external;
}
