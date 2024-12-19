// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {IAddressProviderV3_1} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProviderV3_1.sol";

import {
    AP_ACL,
    AP_CONTRACTS_REGISTER,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/governance/contracts/libraries/ContractLiterals.sol";

import {ACL} from "@gearbox-protocol/governance/contracts/market/ACL.sol";
import {IContractsRegisterExt} from "./interfaces/IContractsRegisterExt.sol";

abstract contract ForkTest is Test {
    IAddressProviderV3_1 addressProvider;
    ACL acl;
    IContractsRegisterExt register;
    address configurator;

    modifier onlyFork() {
        if (address(addressProvider) != address(0)) _;
    }

    function _createFork() internal {
        string memory rpcUrl = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        uint256 blockNumber = vm.envOr("FORK_BLOCK_NUMBER", type(uint256).max);
        if (blockNumber == type(uint256).max) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, blockNumber);
        }

        addressProvider = IAddressProviderV3_1(vm.envAddress("FORK_ADDRESS_PROVIDER"));
        acl = ACL(addressProvider.getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL));
        register = IContractsRegisterExt(addressProvider.getAddressOrRevert(AP_CONTRACTS_REGISTER, NO_VERSION_CONTROL));
        configurator = acl.owner();
    }
}
