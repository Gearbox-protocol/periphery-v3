// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";

import {ISecuritizeDegenNFT} from "../interfaces/ISecuritizeDegenNFT.sol";
import {ISecuritizeKYCFactory} from "../interfaces/ISecuritizeKYCFactory.sol";
import {IVaultRegistrar} from "../interfaces/external/securitize/IVaultRegistrar.sol";
import {
    AddressValidation,
    TYPE_INSTANCE_MANAGER_PROXY,
    TYPE_SECURITIZE_DEGEN_NFT
} from "../libraries/AddressValidation.sol";

/// @title  Securitize Degen NFT
/// @author Gearbox Foundation
/// @notice A Degen NFT that handles the registration of credit accounts and helper accounts in Securitize registries
///         through `VaultRegistrar` contracts, and prevents users from opening non-compliant credit accounts.
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
    mapping(address investor => mapping(address token => Signature)) internal _cachedSignatures;

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

    function getCachedSignature(address creditAccount, address token)
        external
        view
        override
        returns (Signature memory)
    {
        return _cachedSignatures[_getInvestor(creditAccount)][token];
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

    function registerCreditAccount(address creditAccount, RegisterMessage[] calldata messages)
        external
        override
        onlyFactory
    {
        address investor = _getInvestor(creditAccount);
        address wallet = _FACTORY.getWallet(creditAccount);
        uint256 length = messages.length;
        for (uint256 i; i < length; ++i) {
            address token = messages[i].token;
            if (!_registeredTokensSet[creditAccount].add(token)) continue;
            address registrar = getRegistrar(token);
            _registerVault(registrar, investor, creditAccount, messages[i].signature);
            _registerVault(registrar, investor, wallet, messages[i].signature);
            _cachedSignatures[investor][token] = messages[i].signature;
        }
    }

    function registerHelperAccount(address creditAccount, address helperAccount, RegisterMessage calldata message)
        external
        override
        onlyOperator(message.token)
    {
        address investor = _getInvestor(creditAccount);
        _registerVault(getRegistrar(message.token), investor, helperAccount, message.signature);
        _cachedSignatures[investor][message.token] = message.signature;
    }

    function registerHelperAccount(address creditAccount, address helperAccount, address token)
        external
        override
        onlyOperator(token)
    {
        address investor = _getInvestor(creditAccount);
        Signature memory signature = _cachedSignatures[investor][token];
        _registerVault(getRegistrar(token), investor, helperAccount, signature);
    }

    /// @dev This contract is expected to have the operator role in `registrar`
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

    function _getInvestor(address creditAccount) internal view returns (address) {
        return _FACTORY.getInvestor(creditAccount);
    }

    function _registerVault(address registrar, address investor, address vault, Signature memory signature) internal {
        if (IVaultRegistrar(registrar).isRegistered(vault, investor)) return;
        IVaultRegistrar(registrar).registerVault(vault, investor, signature.deadline, signature.signature);
    }
}
