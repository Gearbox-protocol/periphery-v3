// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {SecuritizeWallet} from "./SecuritizeWallet.sol";
import {ISecuritizeFactory} from "./interfaces/ISecuritizeFactory.sol";
import {IVaultWhitelister} from "./interfaces/IVaultWhitelister.sol";
import {
    AP_SECURITIZE_ADMIN,
    AP_SECURITIZE_FACTORY,
    NO_VERSION_CONTROL,
    AddressValidation
} from "./libraries/AddressValidation.sol";

/// @title Securitize Factory
/// @author Gearbox Foundation
/// @notice A factory contract that allows investors to open credit accounts whitelisted to interact
///         with DSTokens by Securitize while also allowing the latter to enforce compliance
contract SecuritizeFactory is ISecuritizeFactory {
    using AddressValidation for IAddressProvider;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct CreditAccountInfo {
        address wallet;
        address investor;
        bool frozen;
    }

    struct InvestorInfo {
        uint256 nonce;
        EnumerableSet.AddressSet creditAccounts;
    }

    bytes32 public constant override contractType = AP_SECURITIZE_FACTORY;
    uint256 public constant override version = 3_10;

    IAddressProvider public immutable ADDRESS_PROVIDER;

    mapping(address creditManager => address whitelister) internal _whitelisters;

    mapping(address creditAccount => CreditAccountInfo) internal _creditAccountInfo;

    mapping(address investor => InvestorInfo) internal _investorInfo;

    modifier onlySecuritizeAdmin() {
        _ensureCallerIsSecuritizeAdmin();
        _;
    }

    modifier nonZeroAddress(address addr) {
        _ensureAddressIsNotZero(addr);
        _;
    }

    modifier onlyCreditAccountFromFactory(address creditAccount) {
        _ensureCreditAccountIsFromFactory(creditAccount);
        _;
    }

    constructor(IAddressProvider addressProvider) {
        ADDRESS_PROVIDER = addressProvider;
    }

    // ------- //
    // GETTERS //
    // ------- //

    function isCreditAccountFromFactory(address creditAccount) public view override returns (bool) {
        return _creditAccountInfo[creditAccount].wallet != address(0);
    }

    function getWallet(address creditAccount)
        external
        view
        override
        onlyCreditAccountFromFactory(creditAccount)
        returns (address)
    {
        return _creditAccountInfo[creditAccount].wallet;
    }

    function getInvestor(address creditAccount)
        external
        view
        override
        onlyCreditAccountFromFactory(creditAccount)
        returns (address)
    {
        return _creditAccountInfo[creditAccount].investor;
    }

    function isFrozen(address creditAccount)
        external
        view
        override
        onlyCreditAccountFromFactory(creditAccount)
        returns (bool)
    {
        return _creditAccountInfo[creditAccount].frozen;
    }

    function getCreditAccounts(address investor) external view override returns (address[] memory) {
        return _investorInfo[investor].creditAccounts.values();
    }

    function getWhitelister(address creditManager) external view override returns (address) {
        return _whitelisters[creditManager];
    }

    // -------------- //
    // USER FUNCTIONS //
    // -------------- //

    function precomputeWalletAddress(address creditManager, address investor) external view override returns (address) {
        return Create2.computeAddress(_getSalt(investor), keccak256(_getWalletBytecode(creditManager)));
    }

    function openCreditAccount(address creditManager)
        external
        override
        returns (address creditAccount, address wallet)
    {
        address whitelister = _whitelisters[creditManager];
        if (whitelister == address(0)) revert CreditManagerNotAddedException(creditManager);

        wallet = Create2.deploy(0, _getSalt(msg.sender), _getWalletBytecode(creditManager));
        creditAccount = SecuritizeWallet(wallet).CREDIT_ACCOUNT();

        IVaultWhitelister(whitelister).whitelist(creditAccount, msg.sender);
        IVaultWhitelister(whitelister).whitelist(wallet, msg.sender);

        _investorInfo[msg.sender].nonce++;
        _investorInfo[msg.sender].creditAccounts.add(creditAccount);
        _creditAccountInfo[creditAccount] = CreditAccountInfo({wallet: wallet, investor: msg.sender, frozen: false});

        emit OpenCreditAccount(creditAccount, wallet, msg.sender);
    }

    // --------------- //
    // ADMIN FUNCTIONS //
    // --------------- //

    /// @dev This factory is expected to have proper permissions in `whitelister`
    function addCreditManager(address creditManager, address whitelister)
        external
        onlySecuritizeAdmin
        nonZeroAddress(whitelister)
    {
        if (_whitelisters[creditManager] != address(0)) {
            revert CreditManagerAlreadyAddedException(creditManager);
        }
        if (!ADDRESS_PROVIDER.isCreditManager(creditManager)) revert InvalidCreditManagerException(creditManager);
        address underlying = ICreditManagerV3(creditManager).underlying();
        if (!ADDRESS_PROVIDER.isSecuritizeUnderlying(underlying)) revert InvalidUnderlyingTokenException(underlying);

        _whitelisters[creditManager] = whitelister;
        emit AddCreditManager(creditManager, whitelister);
    }

    function setInvestor(address creditAccount, address investor)
        external
        override
        onlySecuritizeAdmin
        nonZeroAddress(investor)
        onlyCreditAccountFromFactory(creditAccount)
    {
        address oldInvestor = _creditAccountInfo[creditAccount].investor;
        if (investor == oldInvestor) return;
        _creditAccountInfo[creditAccount].investor = investor;
        _investorInfo[investor].creditAccounts.add(creditAccount);
        _investorInfo[oldInvestor].creditAccounts.remove(creditAccount);
        emit SetInvestor(creditAccount, oldInvestor, investor);
    }

    function freeze(address creditAccount)
        external
        override
        onlySecuritizeAdmin
        onlyCreditAccountFromFactory(creditAccount)
    {
        if (_creditAccountInfo[creditAccount].frozen) return;
        _creditAccountInfo[creditAccount].frozen = true;
        emit FreezeCreditAccount(creditAccount);
    }

    function unfreeze(address creditAccount)
        external
        override
        onlySecuritizeAdmin
        onlyCreditAccountFromFactory(creditAccount)
    {
        if (!_creditAccountInfo[creditAccount].frozen) return;
        _creditAccountInfo[creditAccount].frozen = false;
        emit UnfreezeCreditAccount(creditAccount);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _ensureCallerIsSecuritizeAdmin() internal view {
        if (msg.sender != ADDRESS_PROVIDER.getAddressOrRevert(AP_SECURITIZE_ADMIN, NO_VERSION_CONTROL)) {
            revert CallerIsNotSecuritizeAdminException(msg.sender);
        }
    }

    function _ensureAddressIsNotZero(address addr) internal pure {
        if (addr == address(0)) revert ZeroAddressException(addr);
    }

    function _ensureCreditAccountIsFromFactory(address creditAccount) internal view {
        if (!isCreditAccountFromFactory(creditAccount)) revert CreditAccountNotFromFactoryException(creditAccount);
    }

    function _getSalt(address investor) internal view returns (bytes32) {
        return keccak256(abi.encode(investor, _investorInfo[investor].nonce));
    }

    function _getWalletBytecode(address creditManager) internal view returns (bytes memory) {
        return abi.encodePacked(type(SecuritizeWallet).creationCode, abi.encode(address(this), creditManager));
    }
}
