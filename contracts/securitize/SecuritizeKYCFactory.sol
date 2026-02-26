// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IBytecodeRepository} from "@gearbox-protocol/permissionless/contracts/interfaces/IBytecodeRepository.sol";
import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {SecuritizeWallet} from "./SecuritizeWallet.sol";
import {ISecuritizeDegenNFT} from "./interfaces/ISecuritizeDegenNFT.sol";
import {ISecuritizeKYCFactory} from "./interfaces/ISecuritizeKYCFactory.sol";
import {IVaultRegistrar} from "./interfaces/IVaultRegistrar.sol";
import {
    AP_BYTECODE_REPOSITORY,
    AP_INSTANCE_MANAGER_PROXY,
    DOMAIN_KYC_UNDERLYING,
    NO_VERSION_CONTROL,
    TYPE_SECURITIZE_DEGEN_NFT,
    TYPE_SECURITIZE_KYC_FACTORY,
    AddressValidation
} from "./libraries/AddressValidation.sol";

/// @title  Securitize KYC Factory
/// @author Gearbox Foundation
/// @notice A factory contract that allows investors to open credit accounts whitelisted to interact
///         with DSTokens by Securitize while also allowing the latter to enforce KYC compliance
contract SecuritizeKYCFactory is ISecuritizeKYCFactory, Ownable2Step {
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

    bytes32 public constant override contractType = TYPE_SECURITIZE_KYC_FACTORY;
    uint256 public constant override version = 3_10;

    IAddressProvider internal immutable _ADDRESS_PROVIDER;
    ISecuritizeDegenNFT internal immutable _DEGEN_NFT;

    EnumerableSet.AddressSet internal _DSTokensSet;
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

    modifier onlyInstanceOwner() {
        _ensureCallerIsInstanceOwner();
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

    constructor(IAddressProvider addressProvider, address securitizeAdmin) nonZeroAddress(securitizeAdmin) {
        _ADDRESS_PROVIDER = addressProvider;

        address bytecodeRepository = _ADDRESS_PROVIDER.getAddressOrRevert(AP_BYTECODE_REPOSITORY, NO_VERSION_CONTROL);
        _DEGEN_NFT = ISecuritizeDegenNFT(
            IBytecodeRepository(bytecodeRepository)
                .deploy({
                    contractType: TYPE_SECURITIZE_DEGEN_NFT,
                    version: 3_10,
                    constructorParams: abi.encode(_ADDRESS_PROVIDER, this),
                    salt: bytes32(0)
                })
        );

        _transferOwnership(securitizeAdmin);
    }

    // ------- //
    // GETTERS //
    // ------- //

    function getDegenNFT() external view override returns (address) {
        return address(_DEGEN_NFT);
    }

    function getDSTokens() external view override returns (address[] memory) {
        return _DSTokensSet.values();
    }

    function getRegistrar(address token) public view override returns (address registrar) {
        registrar = _registrars[token];
        if (registrar == address(0)) revert RegistrarNotSetForTokenException(token);
    }

    function isCreditAccount(address creditAccount) public view override returns (bool) {
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

    function precomputeWalletAddress(address creditManager, address investor) public view override returns (address) {
        return Create2.computeAddress(_getSalt(investor), keccak256(_getWalletBytecode(creditManager)));
    }

    function openCreditAccount(address creditManager, MultiCall[] calldata calls, address[] calldata tokensToRegister)
        external
        override
        returns (address creditAccount, address wallet)
    {
        if (!_ADDRESS_PROVIDER.isCreditManager(creditManager)) {
            revert InvalidCreditManagerException(creditManager);
        }
        address underlying = ICreditManagerV3(creditManager).underlying();
        if (!_ADDRESS_PROVIDER.hasDomain(underlying, DOMAIN_KYC_UNDERLYING)) {
            revert InvalidUnderlyingTokenException(underlying);
        }

        _DEGEN_NFT.mint(precomputeWalletAddress(creditManager, msg.sender));
        wallet = Create2.deploy(0, _getSalt(msg.sender), _getWalletBytecode(creditManager));
        creditAccount = SecuritizeWallet(wallet).creditAccount();

        _investorInfo[msg.sender].nonce++;
        _investorInfo[msg.sender].creditAccounts.add(creditAccount);
        _creditAccountInfo[creditAccount].wallet = wallet;
        _creditAccountInfo[creditAccount].investor = msg.sender;
        emit CreateWallet(creditAccount, wallet, msg.sender);

        _registerTokens(msg.sender, creditAccount, wallet, tokensToRegister);
        _multicall(wallet, calls);
    }

    function multicall(address creditAccount, MultiCall[] calldata calls, address[] calldata tokensToRegister)
        external
        override
        onlyInvestor(creditAccount)
        whenNotFrozen(creditAccount)
    {
        address wallet = _creditAccountInfo[creditAccount].wallet;
        _registerTokens(msg.sender, creditAccount, wallet, tokensToRegister);
        _multicall(wallet, calls);
    }

    // --------------- //
    // ADMIN FUNCTIONS //
    // --------------- //

    /// @dev This factory is expected to have proper permissions in `registrar`
    function addRegistrar(address registrar) external onlyInstanceOwner nonZeroAddress(registrar) {
        address token = IVaultRegistrar(registrar).token();
        if (token == address(0)) revert ZeroAddressException();
        if (_registrars[token] == registrar) return;
        _DSTokensSet.add(token);
        _registrars[token] = registrar;
        emit SetRegistrar(token, registrar);
    }

    function setFrozenStatus(address creditAccount, bool frozen)
        external
        override
        onlyOwner
        onlyKnownCreditAccounts(creditAccount)
    {
        if (_creditAccountInfo[creditAccount].frozen == frozen) return;
        _creditAccountInfo[creditAccount].frozen = frozen;
        emit SetFrozenStatus(creditAccount, frozen);
    }

    function setInvestor(address creditAccount, address investor)
        external
        override
        onlyOwner
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
        if (investor == address(0)) return;
        _investorInfo[investor].creditAccounts.add(creditAccount);
        _registerTokens(investor, creditAccount, wallet, tokens);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _ensureAddressIsNotZero(address addr) internal pure {
        if (addr == address(0)) revert ZeroAddressException();
    }

    function _ensureCallerIsInstanceOwner() internal view {
        if (msg.sender != _ADDRESS_PROVIDER.getAddressOrRevert(AP_INSTANCE_MANAGER_PROXY, NO_VERSION_CONTROL)) {
            revert CallerIsNotInstanceOwnerException(msg.sender);
        }
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
        if (!isCreditAccount(creditAccount)) revert UnknownCreditAccountException(creditAccount);
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
            address registrar = getRegistrar(tokens[i]);
            _registerVault(registrar, creditAccount, investor);
            _registerVault(registrar, wallet, investor);
            _creditAccountInfo[creditAccount].tokens.add(tokens[i]);
        }
    }

    function _unregisterTokens(address investor, address creditAccount, address wallet, address[] memory tokens)
        internal
    {
        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            address registrar = getRegistrar(tokens[i]);
            _unregisterVault(registrar, creditAccount, investor);
            _unregisterVault(registrar, wallet, investor);
            _creditAccountInfo[creditAccount].tokens.remove(tokens[i]);
        }
    }

    function _multicall(address wallet, MultiCall[] calldata calls) internal {
        SecuritizeWallet(wallet).multicall(calls);
    }

    function _registerVault(address registrar, address vault, address investor) internal {
        IVaultRegistrar(registrar).registerVault(vault, investor);
    }

    function _unregisterVault(address registrar, address vault, address investor) internal {
        IVaultRegistrar(registrar).unregisterVault(vault, investor);
    }
}
