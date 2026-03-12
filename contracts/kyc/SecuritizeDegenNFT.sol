// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";

import {ISecuritizeDegenNFT} from "../interfaces/ISecuritizeDegenNFT.sol";
import {ISecuritizeKYCFactory} from "../interfaces/ISecuritizeKYCFactory.sol";
import {IVaultRegistrar} from "../interfaces/external/IVaultRegistrar.sol";
import {
    AddressValidation,
    TYPE_INSTANCE_MANAGER_PROXY,
    TYPE_SECURITIZE_DEGEN_NFT
} from "../libraries/AddressValidation.sol";

/// @title  Securitize Degen NFT
/// @author Gearbox Foundation
/// @notice A Degen NFT contract that can be used to prevent users from opening non-compliant credit accounts.
contract SecuritizeDegenNFT is ISecuritizeDegenNFT {
    using AddressValidation for IAddressProvider;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant override contractType = TYPE_SECURITIZE_DEGEN_NFT;
    uint256 public constant override version = 3_10;

    IAddressProvider internal immutable _ADDRESS_PROVIDER;
    ISecuritizeKYCFactory internal immutable _FACTORY;

    EnumerableSet.AddressSet internal _walletsSet;
    EnumerableSet.AddressSet internal _DSTokensSet;
    mapping(address token => address) internal _registrars;
    mapping(address token => EnumerableSet.AddressSet) internal _operatorsSet;
    mapping(address creditAccount => EnumerableSet.AddressSet) internal _registeredTokensSet;

    // --------- //
    // MODIFIERS //
    // --------- //

    modifier onlyFactory() {
        _ensureCallerIsFactory();
        _;
    }

    modifier onlyOperator(address token) {
        _ensureCallerIsOperator(token);
        _;
    }

    modifier onlyInstanceOwner() {
        _ensureCallerIsInstanceOwner();
        _;
    }

    // ----------- //
    // CONSTRUCTOR //
    // ----------- //

    constructor(IAddressProvider addressProvider, ISecuritizeKYCFactory factory) {
        _ADDRESS_PROVIDER = addressProvider;
        _FACTORY = factory;
    }

    // ------- //
    // GETTERS //
    // ------- //

    function serialize() external view override returns (bytes memory) {
        uint256 length = _DSTokensSet.length();
        address[] memory tokens = new address[](length);
        address[] memory registrars = new address[](length);
        for (uint256 i; i < length; ++i) {
            tokens[i] = _DSTokensSet.at(i);
            registrars[i] = _registrars[tokens[i]];
        }
        return abi.encode(_FACTORY, tokens, registrars);
    }

    function getFactory() external view override returns (address) {
        return address(_FACTORY);
    }

    function getOperators(address token) external view override returns (address[] memory) {
        return _operatorsSet[token].values();
    }

    function isOperator(address token, address operator) external view override returns (bool) {
        return _operatorsSet[token].contains(operator);
    }

    function getDSTokens() external view override returns (address[] memory) {
        return _DSTokensSet.values();
    }

    function isDSToken(address token) external view override returns (bool) {
        return _DSTokensSet.contains(token);
    }

    function getRegistrar(address token) public view override returns (address registrar) {
        registrar = _registrars[token];
        if (registrar == address(0)) revert RegistrarNotSetForTokenException(token);
    }

    function getRegisteredTokens(address creditAccount) external view override returns (address[] memory) {
        return _registeredTokensSet[creditAccount].values();
    }

    // ------- //
    // ACTIONS //
    // ------- //

    function mint(address wallet) external override onlyFactory {
        if (_walletsSet.add(wallet)) emit Mint(wallet);
    }

    function burn(address wallet, uint256) external override {
        if (!_ADDRESS_PROVIDER.isCreditFacade(msg.sender)) revert CallerIsNotCreditFacadeException(msg.sender);
        if (!_walletsSet.contains(wallet)) revert UnknownWalletException(wallet);
        emit Burn(wallet);
    }

    function registerCreditAccount(address creditAccount, address[] calldata tokens) external override onlyFactory {
        address investor = _FACTORY.getInvestor(creditAccount);
        address wallet = _FACTORY.getWallet(creditAccount);
        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            address token = tokens[i];
            if (!_registeredTokensSet[creditAccount].add(token)) continue;
            _registerVault(token, investor, creditAccount);
            _registerVault(token, investor, wallet);
        }
    }

    function registerHelperAccount(address creditAccount, address helperAccount, address token)
        external
        override
        onlyOperator(token)
    {
        // NOTE: this really works because Securitize contracts don't distinguish `investorWalletAddress` and
        // `vaultAddress` under the hood, both are just accounts registered under the same investor ID;
        // be very cautious when reusing this codebase for other projects with `VaultRegistrar`
        _registerVault(token, creditAccount, helperAccount);
    }

    /// @dev This contract is expected to have proper permissions in `registrar`
    function addRegistrar(address registrar) external override onlyInstanceOwner {
        address token = IVaultRegistrar(registrar).token();
        if (!_ADDRESS_PROVIDER.isKnownToken(token)) revert UnknownTokenException(token);
        if (_registrars[token] == registrar) return;
        _DSTokensSet.add(token);
        _registrars[token] = registrar;
        emit SetRegistrar(token, registrar);
    }

    function setOperatorStatus(address token, address operator, bool approved) external override onlyInstanceOwner {
        if (approved && _operatorsSet[token].add(operator) || !approved && _operatorsSet[token].remove(operator)) {
            emit SetOperatorStatus(token, operator, approved);
        }
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _ensureCallerIsFactory() internal view {
        if (msg.sender != address(_FACTORY)) revert CallerIsNotFactoryException(msg.sender);
    }

    function _ensureCallerIsOperator(address token) internal view {
        if (!_operatorsSet[token].contains(msg.sender)) revert CallerIsNotOperatorException(token, msg.sender);
    }

    function _ensureCallerIsInstanceOwner() internal view {
        if (msg.sender != _ADDRESS_PROVIDER.getGlobalAddress(TYPE_INSTANCE_MANAGER_PROXY)) {
            revert CallerIsNotInstanceOwnerException(msg.sender);
        }
    }

    function _registerVault(address token, address wallet, address vault) internal {
        address registrar = getRegistrar(token);
        // NOTE: in case multiple DS tokens share the same registry service
        if (IVaultRegistrar(registrar).isRegistered(vault, wallet)) return;
        IVaultRegistrar(registrar).registerVault(vault, wallet);
    }
}
