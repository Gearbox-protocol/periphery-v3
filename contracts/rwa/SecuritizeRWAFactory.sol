// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IACL} from "@gearbox-protocol/permissionless/contracts/interfaces/IACL.sol";
import {IBytecodeRepository} from "@gearbox-protocol/permissionless/contracts/interfaces/IBytecodeRepository.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {SecuritizeWallet} from "./SecuritizeWallet.sol";
import {ISecuritizeDegenNFT} from "../interfaces/ISecuritizeDegenNFT.sol";
import {ISecuritizeRWAFactory} from "../interfaces/ISecuritizeRWAFactory.sol";
import {
    AddressValidation,
    DOMAIN_RWA_UNDERLYING,
    ROLE_OPENING_SIGNER,
    TYPE_BYTECODE_REPOSITORY,
    TYPE_INSTANCE_MANAGER_PROXY,
    TYPE_SECURITIZE_DEGEN_NFT,
    TYPE_SECURITIZE_RWA_FACTORY
} from "../libraries/AddressValidation.sol";

/// @title  Securitize RWA Factory
/// @author Gearbox Foundation
/// @notice A factory contract that allows investors to open credit accounts whitelisted to interact
///         with DSTokens by Securitize while also allowing the latter to enforce RWA compliance.
/// @dev Opening can optionally be gated by EIP-712 approvals from `ROLE_OPENING_SIGNER` accounts on
///      the credit manager's market ACL. When `minSignaturesRequired[marketConfigurator] == 0`
///      (default), opening-signature checks are skipped.
contract SecuritizeRWAFactory is ISecuritizeRWAFactory, Ownable2Step, EIP712 {
    using AddressValidation for IAddressProvider;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ----- //
    // TYPES //
    // ----- //

    struct CreditAccountInfo {
        address wallet;
        address investor;
        bool frozen;
    }

    struct InvestorInfo {
        uint256 nonce;
        EnumerableSet.AddressSet creditAccounts;
    }

    // --------------- //
    // STATE VARIABLES //
    // --------------- //

    bytes32 public constant override contractType = TYPE_SECURITIZE_RWA_FACTORY;
    uint256 public constant override version = 3_11;

    /// @notice EIP-712 typehash for opening approvals
    bytes32 public constant MINT_TYPEHASH =
        keccak256("Mint(address creditManager,address accountOwner,uint32 deadline,uint32 nonce)");

    IAddressProvider internal immutable _ADDRESS_PROVIDER;
    ISecuritizeDegenNFT internal immutable _DEGEN_NFT;

    mapping(address creditAccount => CreditAccountInfo) internal _creditAccountInfo;
    mapping(address investor => InvestorInfo) internal _investorInfo;
    mapping(address bot => bool allowed) internal _allowedBots;

    /// @notice Minimum opening signatures required per market configurator (`0` = gate disabled)
    mapping(address marketConfigurator => uint16) public override minSignaturesRequired;

    /// @notice Opening deadline and nonce for `accountOwner` on `creditManager`
    mapping(address accountOwner => mapping(address creditManager => OpeningInfo)) public override openingDeadlines;

    /// @dev Prevents investor from spamming with too many credit accounts
    uint256 internal constant _MAX_SANE_NONCE = 255;

    // --------- //
    // MODIFIERS //
    // --------- //

    modifier nonZeroAddress(address addr) {
        _ensureAddressIsNotZero(addr);
        _;
    }

    modifier onlyKnownCreditAccounts(address creditAccount) {
        _ensureCreditAccountIsKnown(creditAccount);
        _;
    }

    modifier onlyInstanceOwner() {
        _ensureCallerIsInstanceOwner();
        _;
    }

    // ----------- //
    // CONSTRUCTOR //
    // ----------- //

    constructor(IAddressProvider addressProvider, address securitizeAdmin)
        nonZeroAddress(securitizeAdmin)
        EIP712("SecuritizeRWAFactory", "3_11")
    {
        _ADDRESS_PROVIDER = addressProvider;

        address bytecodeRepository = _ADDRESS_PROVIDER.getGlobalAddress(TYPE_BYTECODE_REPOSITORY);
        _DEGEN_NFT = ISecuritizeDegenNFT(
            IBytecodeRepository(bytecodeRepository).deploy({
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

    function serialize() external view override returns (bytes memory) {
        return abi.encode(owner(), _DEGEN_NFT, _DEGEN_NFT.getDSTokensData());
    }

    function getDegenNFT() external view override returns (address) {
        return address(_DEGEN_NFT);
    }

    function getTokens() public view override returns (address[] memory) {
        return _DEGEN_NFT.getDSTokens();
    }

    function isCreditAccount(address creditAccount) public view override returns (bool) {
        return _creditAccountInfo[creditAccount].wallet != address(0);
    }

    function isAllowedBot(address bot) external view override returns (bool) {
        return _allowedBots[bot];
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

    function getCreditAccounts(address investor) external view override returns (address[] memory) {
        return _investorInfo[investor].creditAccounts.values();
    }

    // ------------ //
    // USER ACTIONS //
    // ------------ //

    function precomputeWalletAddress(address creditManager, address investor) public view override returns (address) {
        return Create2.computeAddress(_getSalt(investor), keccak256(_getWalletBytecode(creditManager)));
    }

    function openCreditAccount(
        address creditManager,
        MultiCall[] calldata calls,
        address[] calldata tokensToRegister,
        ISecuritizeDegenNFT.RegisterMessage[] calldata signaturesToCache,
        bytes calldata openingData
    ) external override returns (address creditAccount, address wallet) {
        if (!_ADDRESS_PROVIDER.isCreditManager(creditManager) || _getDegenNFT(creditManager) != address(_DEGEN_NFT)) {
            revert InvalidCreditManagerException(creditManager);
        }
        address underlying = ICreditManagerV3(creditManager).underlying();
        if (!_ADDRESS_PROVIDER.hasDomain(underlying, DOMAIN_RWA_UNDERLYING)) {
            revert InvalidUnderlyingTokenException(underlying);
        }

        _handleOpening(creditManager, msg.sender, openingData);

        _DEGEN_NFT.mint(precomputeWalletAddress(creditManager, msg.sender));
        wallet = Create2.deploy(0, _getSalt(msg.sender), _getWalletBytecode(creditManager));
        creditAccount = SecuritizeWallet(wallet).getCreditAccount();

        _investorInfo[msg.sender].nonce++;
        _investorInfo[msg.sender].creditAccounts.add(creditAccount);
        _creditAccountInfo[creditAccount].wallet = wallet;
        _creditAccountInfo[creditAccount].investor = msg.sender;
        emit OpenRWACreditAccount(creditAccount, wallet, msg.sender);

        if (signaturesToCache.length != 0) {
            _cacheRegisterSignatures(msg.sender, signaturesToCache);
        }
        if (tokensToRegister.length != 0) {
            _registerCreditAccount(creditManager, creditAccount, tokensToRegister);
        }
        _multicall(wallet, calls);
    }

    function multicall(
        address creditAccount,
        MultiCall[] calldata calls,
        address[] calldata tokensToRegister,
        ISecuritizeDegenNFT.RegisterMessage[] calldata signaturesToCache
    ) external override {
        CreditAccountInfo memory creditAccountInfo = _creditAccountInfo[creditAccount];
        if (msg.sender != creditAccountInfo.investor) revert CallerIsNotInvestorException(msg.sender, creditAccount);
        if (creditAccountInfo.frozen) revert FrozenCreditAccountException(creditAccount);

        if (signaturesToCache.length != 0) {
            _cacheRegisterSignatures(creditAccountInfo.investor, signaturesToCache);
        }
        if (tokensToRegister.length != 0) {
            _registerCreditAccount(_getCreditManager(creditAccount), creditAccount, tokensToRegister);
        }
        _multicall(creditAccountInfo.wallet, calls);
    }

    /// @notice Records an opening approval if EIP-712 signatures are valid
    function approveOpening(OpeningSignature[] memory openingSignatures) external override {
        _approveOpening(openingSignatures);
    }

    /// @notice Revokes an opening approval; callable by the credit manager's market emergency admin
    function revokeOpening(address accountOwner, address creditManager) external override {
        _ensureCallerIsEmergencyAdmin(creditManager);
        openingDeadlines[accountOwner][creditManager].deadline = 0;
        openingDeadlines[accountOwner][creditManager].nonce += 1;

        emit RevokeOpening(accountOwner, creditManager);
    }

    // ------------- //
    // ADMIN ACTIONS //
    // ------------- //

    function setCreditAccountFrozenStatus(address creditAccount, bool frozen)
        external
        override
        onlyOwner
        onlyKnownCreditAccounts(creditAccount)
    {
        _setCreditAccountFrozenStatus(creditAccount, frozen);
    }

    function setAllCreditAccountsFrozenStatus(address investor, bool frozen) external override onlyOwner {
        InvestorInfo storage investorInfo = _investorInfo[investor];
        uint256 length = investorInfo.creditAccounts.length();
        for (uint256 i = length; i != 0; --i) {
            address creditAccount = investorInfo.creditAccounts.at(i - 1);
            _setCreditAccountFrozenStatus(creditAccount, frozen);
        }
    }

    function setAllCreditAccountsFrozenStatus(address creditManager, address investor, bool frozen)
        external
        override
        onlyOwner
    {
        InvestorInfo storage investorInfo = _investorInfo[investor];
        uint256 length = investorInfo.creditAccounts.length();
        for (uint256 i = length; i != 0; --i) {
            address creditAccount = investorInfo.creditAccounts.at(i - 1);
            if (_getCreditManager(creditAccount) != creditManager) continue;
            _setCreditAccountFrozenStatus(creditAccount, frozen);
        }
    }

    /// @dev `newInvestor` is expected to be a recognized wallet in all needed registries under the same ID as
    ///      the original investor of `creditAccount`
    function transferCreditAccount(address creditAccount, address newInvestor)
        external
        override
        onlyOwner
        nonZeroAddress(newInvestor)
        onlyKnownCreditAccounts(creditAccount)
    {
        address oldInvestor = _creditAccountInfo[creditAccount].investor;
        if (newInvestor == oldInvestor) return;
        _transferCreditAccount(creditAccount, oldInvestor, newInvestor);
    }

    /// @dev `newInvestor` is expected to be a recognized wallet in all needed registries under the same ID as `investor`
    function transferAllCreditAccounts(address investor, address newInvestor)
        external
        override
        onlyOwner
        nonZeroAddress(newInvestor)
    {
        if (newInvestor == investor) return;
        InvestorInfo storage investorInfo = _investorInfo[investor];
        uint256 length = investorInfo.creditAccounts.length();
        for (uint256 i = length; i != 0; --i) {
            address creditAccount = investorInfo.creditAccounts.at(i - 1);
            _transferCreditAccount(creditAccount, investor, newInvestor);
        }
    }

    /// @dev `newInvestor` is expected to be a recognized wallet in all needed registries under the same ID as `investor`
    function transferAllCreditAccounts(address creditManager, address investor, address newInvestor)
        external
        override
        onlyOwner
        nonZeroAddress(newInvestor)
    {
        if (newInvestor == investor) return;
        InvestorInfo storage investorInfo = _investorInfo[investor];
        uint256 length = investorInfo.creditAccounts.length();
        for (uint256 i = length; i != 0; --i) {
            address creditAccount = investorInfo.creditAccounts.at(i - 1);
            if (_getCreditManager(creditAccount) != creditManager) continue;
            _transferCreditAccount(creditAccount, investor, newInvestor);
        }
    }

    /// @dev Changes the status of whether a bot is allowed
    function setAllowedBotStatus(address bot, bool allowed) external override onlyOwner {
        bool prev = _allowedBots[bot];
        if (allowed != prev) {
            _allowedBots[bot] = allowed;
            emit SetAllowedBotStatus(bot, allowed);
        }
    }

    /// @notice Sets opening-signature threshold for `marketConfigurator` (`0` disables the gate)
    function setMinSignaturesRequired(address marketConfigurator, uint16 minSignaturesRequired_)
        external
        override
        onlyInstanceOwner
    {
        if (minSignaturesRequired[marketConfigurator] == minSignaturesRequired_) return;
        minSignaturesRequired[marketConfigurator] = minSignaturesRequired_;
        emit SetMinSignaturesRequired(marketConfigurator, minSignaturesRequired_);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    function _handleOpening(address creditManager, address investor, bytes calldata openingData) internal {
        address marketConfigurator = _getMarketConfigurator(creditManager);
        uint16 threshold = minSignaturesRequired[marketConfigurator];
        if (threshold == 0) return;

        if (openingData.length != 0) {
            OpeningSignature[] memory openingSignatures = abi.decode(openingData, (OpeningSignature[]));
            if (
                openingSignatures[0].accountOwner != investor || openingSignatures[0].creditManager != creditManager
            ) {
                revert InvalidSignatureParamsException();
            }
            _approveOpening(openingSignatures);
        }

        _consumeOpening(investor, creditManager);
    }

    function _consumeOpening(address accountOwner, address creditManager) internal {
        if (block.timestamp > openingDeadlines[accountOwner][creditManager].deadline) revert CannotOpenException();
        openingDeadlines[accountOwner][creditManager].deadline = 0;

        emit ConsumeOpening(accountOwner, creditManager);
    }

    function _approveOpening(OpeningSignature[] memory openingSignatures) internal {
        address creditManager;
        address accountOwner;
        uint32 deadline;
        uint32 nonce;
        bytes32 digest;
        uint16 nSignatures;
        address prevSigner;

        address marketConfigurator = _getMarketConfigurator(openingSignatures[0].creditManager);
        uint16 threshold = minSignaturesRequired[marketConfigurator];
        address acl = IMarketConfigurator(marketConfigurator).acl();

        for (uint256 i = 0; i < openingSignatures.length; i++) {
            if (i == 0) {
                creditManager = openingSignatures[i].creditManager;
                accountOwner = openingSignatures[i].accountOwner;
                deadline = openingSignatures[i].deadline;
                nonce = openingSignatures[i].nonce;
                digest = _hashTypedDataV4(
                    keccak256(abi.encode(MINT_TYPEHASH, creditManager, accountOwner, deadline, nonce))
                );
            } else {
                if (
                    openingSignatures[i].creditManager != creditManager
                        || openingSignatures[i].accountOwner != accountOwner
                        || openingSignatures[i].deadline != deadline || openingSignatures[i].nonce != nonce
                ) revert OpeningParamsMismatchException();
            }

            address signer = ECDSA.recover(digest, openingSignatures[i].signature);
            if (uint160(signer) <= uint160(prevSigner)) revert IncorrectSignerSortingException();
            prevSigner = signer;

            if (IACL(acl).hasRole(ROLE_OPENING_SIGNER, signer)) nSignatures++;
        }

        if (nSignatures < threshold) revert NotEnoughSignersException();

        if (nonce == openingDeadlines[accountOwner][creditManager].nonce) {
            return;
        } else if (nonce != openingDeadlines[accountOwner][creditManager].nonce + 1) {
            revert IncorrectNonceException();
        }

        if (block.timestamp > deadline) revert StaleOpeningException();

        openingDeadlines[accountOwner][creditManager].deadline = deadline;
        openingDeadlines[accountOwner][creditManager].nonce = nonce;

        emit ApproveOpening(accountOwner, creditManager, deadline);
    }

    function _ensureAddressIsNotZero(address addr) internal pure {
        if (addr == address(0)) revert ZeroAddressException();
    }

    function _ensureCreditAccountIsKnown(address creditAccount) internal view {
        if (!isCreditAccount(creditAccount)) revert UnknownCreditAccountException(creditAccount);
    }

    function _ensureCallerIsInstanceOwner() internal view {
        if (msg.sender != _ADDRESS_PROVIDER.getGlobalAddress(TYPE_INSTANCE_MANAGER_PROXY)) {
            revert CallerIsNotInstanceOwnerException(msg.sender);
        }
    }

    function _ensureCallerIsEmergencyAdmin(address creditManager) internal view {
        address marketConfigurator = _getMarketConfigurator(creditManager);
        if (msg.sender != IMarketConfigurator(marketConfigurator).emergencyAdmin()) {
            revert CallerIsNotEmergencyAdminException(msg.sender);
        }
    }

    function _getSalt(address investor) internal view returns (bytes32) {
        uint256 nonce = _investorInfo[investor].nonce;
        if (nonce > _MAX_SANE_NONCE) revert TooManyCreditAccountsException(investor);
        return keccak256(abi.encode(investor, nonce));
    }

    function _getWalletBytecode(address creditManager) internal view returns (bytes memory) {
        return abi.encodePacked(type(SecuritizeWallet).creationCode, abi.encode(address(this), creditManager));
    }

    function _getDegenNFT(address creditManager) internal view returns (address) {
        return ICreditFacadeV3(ICreditManagerV3(creditManager).creditFacade()).degenNFT();
    }

    function _getMarketConfigurator(address creditManager) internal view returns (address) {
        return AddressValidation.getMarketConfigurator(ICreditManagerV3(creditManager).creditConfigurator());
    }

    function _getCreditManager(address creditAccount) internal view returns (address) {
        return ICreditAccountV3(creditAccount).creditManager();
    }

    function _cacheRegisterSignatures(address investor, ISecuritizeDegenNFT.RegisterMessage[] calldata signatures)
        internal
    {
        ISecuritizeDegenNFT(_DEGEN_NFT).cacheRegisterSignatures(investor, signatures);
    }

    function _registerCreditAccount(address creditManager, address creditAccount, address[] calldata tokens) internal {
        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            ICreditManagerV3(creditManager).getTokenMaskOrRevert(tokens[i]);
        }
        _DEGEN_NFT.registerCreditAccount(creditAccount, tokens);
    }

    function _multicall(address wallet, MultiCall[] calldata calls) internal {
        SecuritizeWallet(wallet).multicall(calls);
    }

    function _setCreditAccountFrozenStatus(address creditAccount, bool frozen) internal {
        if (_creditAccountInfo[creditAccount].frozen == frozen) return;
        _creditAccountInfo[creditAccount].frozen = frozen;
        emit SetCreditAccountFrozenStatus(creditAccount, frozen);
    }

    function _transferCreditAccount(address creditAccount, address oldInvestor, address newInvestor) internal {
        _creditAccountInfo[creditAccount].investor = newInvestor;
        emit TransferCreditAccount(creditAccount, oldInvestor, newInvestor);

        _investorInfo[oldInvestor].creditAccounts.remove(creditAccount);
        _investorInfo[newInvestor].creditAccounts.add(creditAccount);
    }
}
