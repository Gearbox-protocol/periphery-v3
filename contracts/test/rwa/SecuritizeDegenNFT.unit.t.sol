// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";

import {ISecuritizeDegenNFT} from "../../interfaces/ISecuritizeDegenNFT.sol";
import {ISecuritizeRWAFactory} from "../../interfaces/ISecuritizeRWAFactory.sol";
import {SecuritizeDegenNFT} from "../../rwa/SecuritizeDegenNFT.sol";

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
    mapping(address => bytes32) internal _hashes;

    function setDeployed(address deployedContract, bytes32 hash) external {
        _hashes[deployedContract] = hash;
    }

    function getDeployedContractBytecodeHash(address deployedContract) external view returns (bytes32) {
        return _hashes[deployedContract];
    }
}

/// @title SecuritizeDegenNFT burn authorization unit tests
/// @notice Covers parent-vs-credit-facade exclusive burn auth after audit fix
contract SecuritizeDegenNFTUnitTest is Test {
    bytes32 internal constant BYTECODE_REPOSITORY = "BYTECODE_REPOSITORY";

    MockAddressProvider internal addressProvider;
    MockBytecodeRepository internal bytecodeRepository;

    address internal factory;
    address internal parent;
    address internal wallet;
    address internal stranger;

    function setUp() public {
        addressProvider = new MockAddressProvider();
        bytecodeRepository = new MockBytecodeRepository();
        // NO_VERSION_CONTROL == 0
        addressProvider.setAddress(BYTECODE_REPOSITORY, 0, address(bytecodeRepository));

        factory = address(this);
        parent = makeAddr("parent");
        wallet = makeAddr("wallet");
        stranger = makeAddr("stranger");
    }

    // ---------------------- //
    // PARENT DEGEN NFT SET //
    // ---------------------- //

    function test_SDN_01_burn_withParent_allowsParent() public {
        SecuritizeDegenNFT degenNFT = _deployWithParent(parent);
        degenNFT.mint(wallet);

        vm.expectEmit(true, false, false, false, address(degenNFT));
        emit ISecuritizeDegenNFT.Burn(wallet);

        vm.prank(parent);
        degenNFT.burn(wallet, 1);
    }

    function test_SDN_02_burn_withParent_revertsForNonParent() public {
        SecuritizeDegenNFT degenNFT = _deployWithParent(parent);
        degenNFT.mint(wallet);

        // Credit facade must not burn when a parent is configured
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotParentDegenNFTException.selector, stranger));
        degenNFT.burn(wallet, 1);
    }

    function test_SDN_03_burn_withParent_revertsForFactory() public {
        SecuritizeDegenNFT degenNFT = _deployWithParent(parent);
        degenNFT.mint(wallet);

        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotParentDegenNFTException.selector, factory));
        degenNFT.burn(wallet, 1);
    }

    // ------------------------ //
    // NO PARENT DEGEN NFT SET //
    // ------------------------ //

    function test_SDN_04_burn_withoutParent_revertsForNonCreditFacade() public {
        SecuritizeDegenNFT degenNFT = _deployWithParent(address(0));
        degenNFT.mint(wallet);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotCreditFacadeException.selector, stranger));
        degenNFT.burn(wallet, 1);
    }

    function test_SDN_05_burn_withoutParent_revertsForParentAddress() public {
        // Even a designated "parent" address cannot burn when parentDegenNFT is unset
        SecuritizeDegenNFT degenNFT = _deployWithParent(address(0));
        degenNFT.mint(wallet);

        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotCreditFacadeException.selector, parent));
        degenNFT.burn(wallet, 1);
    }

    function test_SDN_06_burn_revertsForUnknownWallet() public {
        SecuritizeDegenNFT degenNFT = _deployWithParent(parent);

        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.UnknownWalletException.selector, wallet));
        degenNFT.burn(wallet, 1);
    }

    // ------- //
    // HELPERS //
    // ------- //

    function _deployWithParent(address parentDegenNFT) internal returns (SecuritizeDegenNFT) {
        return new SecuritizeDegenNFT(
            IAddressProvider(address(addressProvider)), ISecuritizeRWAFactory(factory), parentDegenNFT
        );
    }
}
