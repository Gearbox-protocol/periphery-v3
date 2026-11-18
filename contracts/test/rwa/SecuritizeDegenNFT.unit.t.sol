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

/// @title SecuritizeDegenNFT burn authorization / parent setter unit tests
contract SecuritizeDegenNFTUnitTest is Test {
    bytes32 internal constant BYTECODE_REPOSITORY = "BYTECODE_REPOSITORY";
    bytes32 internal constant INSTANCE_MANAGER_PROXY = "INSTANCE_MANAGER_PROXY";

    MockAddressProvider internal addressProvider;
    MockBytecodeRepository internal bytecodeRepository;
    SecuritizeDegenNFT internal degenNFT;

    address internal factory;
    address internal instanceOwner;
    address internal parent;
    address internal wallet;
    address internal stranger;

    function setUp() public {
        addressProvider = new MockAddressProvider();
        bytecodeRepository = new MockBytecodeRepository();
        // NO_VERSION_CONTROL == 0
        addressProvider.setAddress(BYTECODE_REPOSITORY, 0, address(bytecodeRepository));

        factory = address(this);
        instanceOwner = makeAddr("instanceOwner");
        parent = makeAddr("parent");
        wallet = makeAddr("wallet");
        stranger = makeAddr("stranger");

        addressProvider.setAddress(INSTANCE_MANAGER_PROXY, 0, instanceOwner);

        degenNFT = new SecuritizeDegenNFT(IAddressProvider(address(addressProvider)), ISecuritizeRWAFactory(factory));
    }

    // --------------------- //
    // SET PARENT DEGEN NFT //
    // --------------------- //

    function test_SDN_00_setParentDegenNFT_byInstanceOwner() public {
        vm.expectEmit(true, false, false, true, address(degenNFT));
        emit ISecuritizeDegenNFT.SetParentDegenNFT(parent);

        vm.prank(instanceOwner);
        degenNFT.setParentDegenNFT(parent);

        assertEq(degenNFT.parentDegenNFT(), parent, "Parent not set");
    }

    function test_SDN_00A_setParentDegenNFT_revertsIfUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotInstanceOwnerException.selector, stranger)
        );
        vm.prank(stranger);
        degenNFT.setParentDegenNFT(parent);
    }

    function test_SDN_00B_setParentDegenNFT_canClearParent() public {
        vm.prank(instanceOwner);
        degenNFT.setParentDegenNFT(parent);

        vm.expectEmit(true, false, false, true, address(degenNFT));
        emit ISecuritizeDegenNFT.SetParentDegenNFT(address(0));

        vm.prank(instanceOwner);
        degenNFT.setParentDegenNFT(address(0));

        assertEq(degenNFT.parentDegenNFT(), address(0), "Parent not cleared");
    }

    // ---------------------- //
    // PARENT DEGEN NFT SET //
    // ---------------------- //

    function test_SDN_01_burn_withParent_allowsParent() public {
        _setParent(parent);
        degenNFT.mint(wallet);

        vm.expectEmit(true, false, false, false, address(degenNFT));
        emit ISecuritizeDegenNFT.Burn(wallet);

        vm.prank(parent);
        degenNFT.burn(wallet, 1);
    }

    function test_SDN_02_burn_withParent_revertsForNonParent() public {
        _setParent(parent);
        degenNFT.mint(wallet);

        // Credit facade must not burn when a parent is configured
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotParentDegenNFTException.selector, stranger));
        degenNFT.burn(wallet, 1);
    }

    function test_SDN_03_burn_withParent_revertsForFactory() public {
        _setParent(parent);
        degenNFT.mint(wallet);

        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotParentDegenNFTException.selector, factory));
        degenNFT.burn(wallet, 1);
    }

    // ------------------------ //
    // NO PARENT DEGEN NFT SET //
    // ------------------------ //

    function test_SDN_04_burn_withoutParent_revertsForNonCreditFacade() public {
        degenNFT.mint(wallet);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotCreditFacadeException.selector, stranger));
        degenNFT.burn(wallet, 1);
    }

    function test_SDN_05_burn_withoutParent_revertsForParentAddress() public {
        // Even a designated "parent" address cannot burn when parentDegenNFT is unset
        degenNFT.mint(wallet);

        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotCreditFacadeException.selector, parent));
        degenNFT.burn(wallet, 1);
    }

    function test_SDN_06_burn_revertsForUnknownWallet() public {
        _setParent(parent);

        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.UnknownWalletException.selector, wallet));
        degenNFT.burn(wallet, 1);
    }

    function test_SDN_07_burn_auth_switchesAfterParentCleared() public {
        _setParent(parent);
        degenNFT.mint(wallet);

        vm.prank(instanceOwner);
        degenNFT.setParentDegenNFT(address(0));

        // Parent can no longer burn once cleared; credit-facade check applies
        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(ISecuritizeDegenNFT.CallerIsNotCreditFacadeException.selector, parent));
        degenNFT.burn(wallet, 1);
    }

    // ------- //
    // HELPERS //
    // ------- //

    function _setParent(address parentDegenNFT) internal {
        vm.prank(instanceOwner);
        degenNFT.setParentDegenNFT(parentDegenNFT);
    }
}
