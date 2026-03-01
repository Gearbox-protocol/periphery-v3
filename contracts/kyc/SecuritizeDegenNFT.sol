// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import {IDegenNFT} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IDegenNFT.sol";
import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";

import {ISecuritizeDegenNFT} from "../interfaces/ISecuritizeDegenNFT.sol";
import {ISecuritizeKYCFactory} from "../interfaces/ISecuritizeKYCFactory.sol";
import {TYPE_SECURITIZE_DEGEN_NFT, AddressValidation} from "../libraries/AddressValidation.sol";

/// @title  Securitize Degen NFT
/// @author Gearbox Foundation
/// @notice A Degen NFT contract that can be used to prevent users from opening non-compliant credit accounts.
contract SecuritizeDegenNFT is ISecuritizeDegenNFT {
    using AddressValidation for IAddressProvider;

    bytes32 public constant override contractType = TYPE_SECURITIZE_DEGEN_NFT;
    uint256 public constant override version = 3_10;

    IAddressProvider internal immutable ADDRESS_PROVIDER;
    address public immutable override factory;

    mapping(address wallet => bool) public override isMinted;

    constructor(IAddressProvider addressProvider, address factory_) {
        ADDRESS_PROVIDER = addressProvider;
        factory = factory_;
    }

    function serialize() external view override returns (bytes memory) {
        return abi.encode(factory);
    }

    function mint(address wallet) external override {
        if (msg.sender != factory) revert CallerIsNotFactoryException(msg.sender);
        if (isMinted[wallet]) revert DegenNFTAlreadyMintedException(wallet);
        isMinted[wallet] = true;
        emit Mint(wallet);
    }

    function burn(address wallet, uint256) external override {
        if (!ADDRESS_PROVIDER.isCreditFacade(msg.sender)) revert CallerIsNotCreditFacadeException(msg.sender);
        if (!isMinted[wallet]) revert DegenNFTNotMintedException(wallet);
        isMinted[wallet] = false;
        emit Burn(wallet);
    }
}
