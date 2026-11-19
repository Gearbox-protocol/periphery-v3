// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";

import {ISecuritizeRWAFactory} from "../../interfaces/ISecuritizeRWAFactory.sol";
import {ROLE_OPENING_SIGNER} from "../../libraries/AddressValidation.sol";
import {SecuritizeDegenNFT} from "../../rwa/SecuritizeDegenNFT.sol";
import {SecuritizeRWAFactory} from "../../rwa/SecuritizeRWAFactory.sol";

contract MockAddressProvider {
    mapping(bytes32 => mapping(uint256 => address)) internal _addresses;

    function setAddress(bytes32 key, uint256 ver, address value) external {
        _addresses[key][ver] = value;
    }

    function getAddressOrRevert(bytes32 key, uint256 ver) external view returns (address) {
        address value = _addresses[key][ver];
        require(value != address(0), "AddressNotFound");
        return value;
    }
}

contract MockBytecodeRepository {
    function deploy(bytes32, uint256, bytes calldata constructorParams, bytes32) external returns (address) {
        (address ap, address factory) = abi.decode(constructorParams, (address, address));
        return address(new SecuritizeDegenNFT(IAddressProvider(ap), ISecuritizeRWAFactory(factory)));
    }
}

contract MockACL {
    address public configurator;
    mapping(bytes32 => mapping(address => bool)) internal _roles;

    constructor(address configurator_) {
        configurator = configurator_;
    }

    function getConfigurator() external view returns (address) {
        return configurator;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function setRole(bytes32 role, address account, bool status) external {
        _roles[role][account] = status;
    }
}

contract MockMarketConfigurator {
    address public acl;
    address public emergencyAdmin;

    constructor(address emergencyAdmin_) {
        emergencyAdmin = emergencyAdmin_;
    }

    function setAcl(address acl_) external {
        acl = acl_;
    }
}

contract MockCreditConfigurator {
    address public acl;

    constructor(address acl_) {
        acl = acl_;
    }
}

contract MockCreditManager {
    address public creditConfigurator;

    constructor(address creditConfigurator_) {
        creditConfigurator = creditConfigurator_;
    }
}

/// @title SecuritizeRWAFactory opening-signature unit tests
contract SecuritizeRWAFactoryOpeningUnitTest is Test {
    bytes32 internal constant BYTECODE_REPOSITORY = "BYTECODE_REPOSITORY";
    bytes32 internal constant INSTANCE_MANAGER_PROXY = "INSTANCE_MANAGER_PROXY";

    uint16 internal constant MIN_SIGNATURES = 2;
    uint32 internal deadline;

    MockAddressProvider internal addressProvider;
    MockBytecodeRepository internal bytecodeRepository;
    SecuritizeRWAFactory internal factory;

    MockMarketConfigurator internal marketConfigurator;
    MockACL internal acl;
    MockCreditManager internal creditManager;

    address internal securitizeAdmin;
    address internal instanceOwner;
    address internal emergencyAdmin;
    address internal user1;

    uint256 internal signer0PrivateKey = 0xA11CE;
    uint256 internal signer1PrivateKey = 0xB0B;
    uint256 internal signer2PrivateKey = 0xC0DE;
    address internal signer0;
    address internal signer1;
    address internal signer2;

    function setUp() public {
        addressProvider = new MockAddressProvider();
        bytecodeRepository = new MockBytecodeRepository();
        addressProvider.setAddress(BYTECODE_REPOSITORY, 0, address(bytecodeRepository));

        securitizeAdmin = makeAddr("securitizeAdmin");
        instanceOwner = makeAddr("instanceOwner");
        emergencyAdmin = makeAddr("emergencyAdmin");
        user1 = makeAddr("user1");
        addressProvider.setAddress(INSTANCE_MANAGER_PROXY, 0, instanceOwner);

        signer0 = vm.addr(signer0PrivateKey);
        signer1 = vm.addr(signer1PrivateKey);
        signer2 = vm.addr(signer2PrivateKey);

        marketConfigurator = new MockMarketConfigurator(emergencyAdmin);
        acl = new MockACL(address(marketConfigurator));
        marketConfigurator.setAcl(address(acl));
        acl.setRole(ROLE_OPENING_SIGNER, signer0, true);
        acl.setRole(ROLE_OPENING_SIGNER, signer1, true);

        creditManager = new MockCreditManager(address(new MockCreditConfigurator(address(acl))));

        factory = new SecuritizeRWAFactory(IAddressProvider(address(addressProvider)), securitizeAdmin);
        deadline = uint32(block.timestamp + 1 days);
    }

    // ----------------------------- //
    // SET MIN SIGNATURES REQUIRED //
    // ----------------------------- //

    function test_SRF_00_setMinSignaturesRequired_byInstanceOwner() public {
        vm.expectEmit(true, false, false, true, address(factory));
        emit ISecuritizeRWAFactory.SetMinSignaturesRequired(address(marketConfigurator), MIN_SIGNATURES);

        vm.prank(instanceOwner);
        factory.setMinSignaturesRequired(address(marketConfigurator), MIN_SIGNATURES);

        assertEq(factory.minSignaturesRequired(address(marketConfigurator)), MIN_SIGNATURES);
    }

    function test_SRF_00A_setMinSignaturesRequired_revertsIfNotInstanceOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISecuritizeRWAFactory.CallerIsNotInstanceOwnerException.selector, address(this))
        );
        factory.setMinSignaturesRequired(address(marketConfigurator), MIN_SIGNATURES);
    }

    // ---------------- //
    // APPROVE OPENING //
    // ---------------- //

    function test_SRF_01_approveOpening_success() public {
        _enableGate();

        ISecuritizeRWAFactory.OpeningSignature[] memory sigs =
            _signedOpenings(address(creditManager), user1, deadline, 1, 2);

        vm.expectEmit(true, true, false, true, address(factory));
        emit ISecuritizeRWAFactory.ApproveOpening(user1, address(creditManager), deadline);

        factory.approveOpening(sigs);

        (uint32 storedDeadline, uint32 storedNonce) = factory.openingDeadlines(user1, address(creditManager));
        assertEq(storedDeadline, deadline);
        assertEq(storedNonce, 1);
    }

    function test_SRF_02_approveOpening_revertsIfNotEnoughSigners() public {
        _enableGate();

        uint256[] memory keys = new uint256[](2);
        keys[0] = signer0PrivateKey;
        keys[1] = signer2PrivateKey; // no ROLE_OPENING_SIGNER

        ISecuritizeRWAFactory.OpeningSignature[] memory sigs =
            _signedOpeningsWithKeys(address(creditManager), user1, deadline, 1, keys);

        vm.expectRevert(ISecuritizeRWAFactory.NotEnoughSignersException.selector);
        factory.approveOpening(sigs);
    }

    function test_SRF_03_approveOpening_revertsIfBelowThreshold() public {
        _enableGate();

        ISecuritizeRWAFactory.OpeningSignature[] memory sigs =
            _signedOpenings(address(creditManager), user1, deadline, 1, 1);

        vm.expectRevert(ISecuritizeRWAFactory.NotEnoughSignersException.selector);
        factory.approveOpening(sigs);
    }

    function test_SRF_04_approveOpening_revertsOnParamsMismatch() public {
        _enableGate();

        ISecuritizeRWAFactory.OpeningSignature[] memory sigs =
            _signedOpenings(address(creditManager), user1, deadline, 1, 2);
        sigs[1].deadline = deadline + 1;

        vm.expectRevert(ISecuritizeRWAFactory.OpeningParamsMismatchException.selector);
        factory.approveOpening(sigs);
    }

    function test_SRF_05_approveOpening_sameNonceIsNoOp() public {
        _enableGate();

        factory.approveOpening(_signedOpenings(address(creditManager), user1, deadline, 1, 2));

        uint32 laterDeadline = deadline + 1 days;
        factory.approveOpening(_signedOpenings(address(creditManager), user1, laterDeadline, 1, 2));

        (uint32 storedDeadline,) = factory.openingDeadlines(user1, address(creditManager));
        assertEq(storedDeadline, deadline, "Deadline should not change on same nonce");
    }

    function test_SRF_06_approveOpening_revertsOnIncorrectNonce() public {
        _enableGate();

        ISecuritizeRWAFactory.OpeningSignature[] memory sigs =
            _signedOpenings(address(creditManager), user1, deadline, 2, 2);

        vm.expectRevert(ISecuritizeRWAFactory.IncorrectNonceException.selector);
        factory.approveOpening(sigs);
    }

    function test_SRF_07_approveOpening_revertsIfStale() public {
        _enableGate();

        uint32 staleDeadline = uint32(block.timestamp - 1);
        ISecuritizeRWAFactory.OpeningSignature[] memory sigs =
            _signedOpenings(address(creditManager), user1, staleDeadline, 1, 2);

        vm.expectRevert(ISecuritizeRWAFactory.StaleOpeningException.selector);
        factory.approveOpening(sigs);
    }

    function test_SRF_08_approveOpening_revertsOnUnsortedSigners() public {
        _enableGate();

        ISecuritizeRWAFactory.OpeningSignature[] memory sigs =
            _signedOpenings(address(creditManager), user1, deadline, 1, 2);
        ISecuritizeRWAFactory.OpeningSignature memory tmp = sigs[0];
        sigs[0] = sigs[1];
        sigs[1] = tmp;

        vm.expectRevert(ISecuritizeRWAFactory.IncorrectSignerSortingException.selector);
        factory.approveOpening(sigs);
    }

    // --------------- //
    // REVOKE OPENING //
    // --------------- //

    function test_SRF_09_revokeOpening_byEmergencyAdmin() public {
        _enableGate();
        factory.approveOpening(_signedOpenings(address(creditManager), user1, deadline, 1, 2));

        vm.expectEmit(true, true, false, true, address(factory));
        emit ISecuritizeRWAFactory.RevokeOpening(user1, address(creditManager));

        vm.prank(emergencyAdmin);
        factory.revokeOpening(user1, address(creditManager));

        (uint32 storedDeadline, uint32 storedNonce) = factory.openingDeadlines(user1, address(creditManager));
        assertEq(storedDeadline, 0);
        assertEq(storedNonce, 2);
    }

    function test_SRF_10_revokeOpening_revertsIfNotEmergencyAdmin() public {
        _enableGate();
        factory.approveOpening(_signedOpenings(address(creditManager), user1, deadline, 1, 2));

        vm.expectRevert(
            abi.encodeWithSelector(ISecuritizeRWAFactory.CallerIsNotEmergencyAdminException.selector, address(this))
        );
        factory.revokeOpening(user1, address(creditManager));
    }

    // ------- //
    // HELPERS //
    // ------- //

    function _enableGate() internal {
        vm.prank(instanceOwner);
        factory.setMinSignaturesRequired(address(marketConfigurator), MIN_SIGNATURES);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("SecuritizeRWAFactory")),
                keccak256(bytes("3_11")),
                block.chainid,
                address(factory)
            )
        );
    }

    function _mintDigest(address creditManager_, address accountOwner, uint32 deadline_, uint32 nonce)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(factory.MINT_TYPEHASH(), creditManager_, accountOwner, deadline_, nonce));
        return ECDSA.toTypedDataHash(_domainSeparator(), structHash);
    }

    function _signedOpenings(
        address creditManager_,
        address accountOwner,
        uint32 deadline_,
        uint32 nonce,
        uint256 count
    ) internal view returns (ISecuritizeRWAFactory.OpeningSignature[] memory) {
        uint256[] memory keys = new uint256[](count);
        uint256[3] memory allKeys = [signer0PrivateKey, signer1PrivateKey, signer2PrivateKey];
        for (uint256 i; i < count; ++i) {
            keys[i] = allKeys[i];
        }
        return _signedOpeningsWithKeys(creditManager_, accountOwner, deadline_, nonce, keys);
    }

    function _signedOpeningsWithKeys(
        address creditManager_,
        address accountOwner,
        uint32 deadline_,
        uint32 nonce,
        uint256[] memory keys
    ) internal view returns (ISecuritizeRWAFactory.OpeningSignature[] memory sigs) {
        _sortKeysByAddress(keys);
        bytes32 digest = _mintDigest(creditManager_, accountOwner, deadline_, nonce);

        sigs = new ISecuritizeRWAFactory.OpeningSignature[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = ISecuritizeRWAFactory.OpeningSignature({
                creditManager: creditManager_,
                accountOwner: accountOwner,
                deadline: deadline_,
                nonce: nonce,
                signature: abi.encodePacked(r, s, v)
            });
        }
    }

    function _sortKeysByAddress(uint256[] memory keys) internal pure {
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                if (uint160(vm.addr(keys[j])) < uint160(vm.addr(keys[i]))) {
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }
    }
}
