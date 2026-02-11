// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {SecuritizeWallet} from "./SecuritizeWallet.sol";
import {ISecuritizeFactory} from "./interfaces/ISecuritizeFactory.sol";
import {IVaultRegistrar} from "./interfaces/IVaultRegistrar.sol";
import {AP_SECURITIZE_FACTORY, NO_VERSION_CONTROL, AddressValidation} from "./libraries/AddressValidation.sol";

/// @title Securitize Factory
/// @author Gearbox Foundation
/// @notice A factory contract that allows investors to open credit accounts whitelisted to interact
///         with DSTokens by Securitize while also allowing the latter to enforce compliance
contract SecuritizeFactory is ISecuritizeFactory {
    using AddressValidation for IAddressProvider;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ----- //
    // TYPES //
    // ----- //

    struct CreditAccountInfo {
        address wallet;
        address investor;
        bool frozen;
        EnumerableSet.AddressSet tokens;
    }

    struct InvestorInfo {
        uint256 nonce;
        EnumerableSet.AddressSet creditAccounts;
    }

    // --------------- //
    // STATE VARIABLES //
    // --------------- //

    bytes32 public constant override contractType = AP_SECURITIZE_FACTORY;

    uint256 public constant override version = 3_10;

    IAddressProvider public immutable ADDRESS_PROVIDER;

    address internal _admin;

    mapping(address token => address registrar) internal _registrars;

    mapping(address creditAccount => CreditAccountInfo) internal _creditAccountInfo;

    mapping(address investor => InvestorInfo) internal _investorInfo;

    // --------- //
    // MODIFIERS //
    // --------- //

    modifier nonZeroAddress(address addr) {
        _ensureAddressIsNotZero(addr);
        _;
    }

    modifier onlyAdmin() {
        _ensureCallerIsAdmin();
        _;
    }

    modifier onlyInvestor(address creditAccount) {
        _ensureCallerIsInvestor(creditAccount);
        _;
    }

    modifier whenNotFrozen(address creditAccount) {
        _ensureCreditAccountIsNotFrozen(creditAccount);
        _;
    }

    modifier onlyKnownCreditAccounts(address creditAccount) {
        _ensureCreditAccountIsKnown(creditAccount);
        _;
    }

    // ----------- //
    // CONSTRUCTOR //
    // ----------- //

    constructor(IAddressProvider addressProvider, address admin) nonZeroAddress(admin) {
        ADDRESS_PROVIDER = addressProvider;
        _admin = admin;
        emit SetAdmin(admin);
    }

    // ------- //
    // GETTERS //
    // ------- //

    function getAdmin() external view override returns (address) {
        return _admin;
    }

    function getRegistrar(address token) external view override returns (address registrar) {
        registrar = _registrars[token];
        if (registrar == address(0)) revert RegistrarNotSetForTokenException(token);
    }

    function isKnownCreditAccount(address creditAccount) public view override returns (bool) {
        return _creditAccountInfo[creditAccount].wallet != address(0);
    }

    function getWallet(address creditAccount)
        external
        view
        override
        onlyKnownCreditAccounts(creditAccount)
        returns (address)
    {
        return _creditAccountInfo[creditAccount].wallet;
    }

    function getInvestor(address creditAccount)
        external
        view
        override
        onlyKnownCreditAccounts(creditAccount)
        returns (address)
    {
        return _creditAccountInfo[creditAccount].investor;
    }

    function isFrozen(address creditAccount)
        external
        view
        override
        onlyKnownCreditAccounts(creditAccount)
        returns (bool)
    {
        return _creditAccountInfo[creditAccount].frozen;
    }

    function getRegisteredTokens(address creditAccount)
        external
        view
        override
        onlyKnownCreditAccounts(creditAccount)
        returns (address[] memory)
    {
        return _creditAccountInfo[creditAccount].tokens.values();
    }

    function getCreditAccounts(address investor) external view override returns (address[] memory) {
        return _investorInfo[investor].creditAccounts.values();
    }

    // -------------- //
    // USER FUNCTIONS //
    // -------------- //

    function precomputeWalletAddress(address creditManager, address investor) external view override returns (address) {
        return Create2.computeAddress(_getSalt(investor), keccak256(_getWalletBytecode(creditManager)));
    }

    function openCreditAccount(address creditManager, bytes[] calldata walletCalls, address[] calldata tokensToRegister)
        external
        override
        returns (address creditAccount, address wallet)
    {
        if (!ADDRESS_PROVIDER.isCreditManager(creditManager)) {
            revert InvalidCreditManagerException(creditManager);
        }
        address underlying = ICreditManagerV3(creditManager).underlying();
        if (!ADDRESS_PROVIDER.isSecuritizeUnderlying(underlying)) revert InvalidUnderlyingTokenException(underlying);

        wallet = Create2.deploy(0, _getSalt(msg.sender), _getWalletBytecode(creditManager));
        creditAccount = SecuritizeWallet(wallet).creditAccount();

        _investorInfo[msg.sender].nonce++;
        _investorInfo[msg.sender].creditAccounts.add(creditAccount);
        _creditAccountInfo[creditAccount].wallet = wallet;
        _creditAccountInfo[creditAccount].investor = msg.sender;
        emit CreateWallet(creditAccount, wallet, msg.sender);

        _registerTokens(msg.sender, creditAccount, wallet, tokensToRegister);
        _executeWalletCalls(wallet, walletCalls);
    }

    function executeWalletCalls(address creditAccount, bytes[] calldata calls, address[] calldata tokensToRegister)
        external
        override
        onlyInvestor(creditAccount)
        whenNotFrozen(creditAccount)
    {
        address wallet = _creditAccountInfo[creditAccount].wallet;
        _registerTokens(msg.sender, creditAccount, wallet, tokensToRegister);
        _executeWalletCalls(wallet, calls);
    }

    // --------------- //
    // ADMIN FUNCTIONS //
    // --------------- //

    function setAdmin(address admin) external onlyAdmin nonZeroAddress(admin) {
        if (admin == _admin) return;
        _admin = admin;
        emit SetAdmin(admin);
    }

    /// @dev This factory is expected to have proper permissions in `whitelister`
    function addRegistrar(address registrar) external onlyAdmin nonZeroAddress(registrar) {
        address token = IVaultRegistrar(registrar).token();
        if (token == address(0)) revert ZeroAddressException();
        if (_registrars[token] == registrar) return;
        _registrars[token] = registrar;
        emit SetRegistrar(token, registrar);
    }

    function setFrozenStatus(address creditAccount, bool frozen)
        external
        override
        onlyAdmin
        onlyKnownCreditAccounts(creditAccount)
    {
        if (_creditAccountInfo[creditAccount].frozen == frozen) return;
        _creditAccountInfo[creditAccount].frozen = frozen;
        emit SetFrozenStatus(creditAccount, frozen);
    }

    function setInvestor(address creditAccount, address investor)
        external
        override
        onlyAdmin
        nonZeroAddress(investor)
        onlyKnownCreditAccounts(creditAccount)
    {
        CreditAccountInfo storage creditAccountInfo = _creditAccountInfo[creditAccount];
        address oldInvestor = creditAccountInfo.investor;
        if (investor == oldInvestor) return;
        creditAccountInfo.investor = investor;
        emit SetInvestor(creditAccount, oldInvestor, investor);

        address wallet = creditAccountInfo.wallet;
        address[] memory tokens = creditAccountInfo.tokens.values();
        _investorInfo[oldInvestor].creditAccounts.remove(creditAccount);
        _unregisterTokens(oldInvestor, creditAccount, wallet, tokens);
        _investorInfo[investor].creditAccounts.add(creditAccount);
        _registerTokens(investor, creditAccount, wallet, tokens);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _ensureAddressIsNotZero(address addr) internal pure {
        if (addr == address(0)) revert ZeroAddressException();
    }

    function _ensureCallerIsAdmin() internal view {
        if (msg.sender != _admin) revert CallerIsNotAdminException(msg.sender);
    }

    function _ensureCallerIsInvestor(address creditAccount) internal view {
        if (msg.sender != _creditAccountInfo[creditAccount].investor) {
            revert CallerIsNotInvestorException(msg.sender, creditAccount);
        }
    }

    function _ensureCreditAccountIsNotFrozen(address creditAccount) internal view {
        if (_creditAccountInfo[creditAccount].frozen) revert FrozenCreditAccountException(creditAccount);
    }

    function _ensureCreditAccountIsKnown(address creditAccount) internal view {
        if (!isKnownCreditAccount(creditAccount)) revert UnknownCreditAccountException(creditAccount);
    }

    function _getSalt(address investor) internal view returns (bytes32) {
        return keccak256(abi.encode(investor, _investorInfo[investor].nonce));
    }

    function _getWalletBytecode(address creditManager) internal view returns (bytes memory) {
        return abi.encodePacked(type(SecuritizeWallet).creationCode, abi.encode(address(this), creditManager));
    }

    function _registerTokens(address investor, address creditAccount, address wallet, address[] memory tokens)
        internal
    {
        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            address token = tokens[i];
            address registrar = _registrars[token];
            if (registrar == address(0)) revert RegistrarNotSetForTokenException(token);
            IVaultRegistrar(registrar).registerVault(creditAccount, investor);
            IVaultRegistrar(registrar).registerVault(wallet, investor);
            _creditAccountInfo[creditAccount].tokens.add(token);
        }
    }

    function _unregisterTokens(address investor, address creditAccount, address wallet, address[] memory tokens)
        internal
    {
        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            address token = tokens[i];
            address registrar = _registrars[token];
            if (registrar == address(0)) revert RegistrarNotSetForTokenException(token);
            IVaultRegistrar(registrar).unregisterVault(creditAccount, investor);
            IVaultRegistrar(registrar).unregisterVault(wallet, investor);
            _creditAccountInfo[creditAccount].tokens.remove(token);
        }
    }

    function _executeWalletCalls(address wallet, bytes[] calldata calls) internal {
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            (bool success, bytes memory result) = wallet.call(calls[i]);
            if (!success) revert WalletCallExecutionFailedException(i, result);
        }
    }
}
