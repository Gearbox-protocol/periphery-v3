// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";

import {ACL} from "@gearbox-protocol/core-v2/contracts/core/ACL.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";

import {
    AP_ACL,
    AP_CONTRACTS_REGISTER,
    IAddressProviderV3,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/core-v3/contracts/interfaces/IAddressProviderV3.sol";

abstract contract ForkTest is Test {
    IAddressProviderV3 addressProvider;
    ACL acl;
    ContractsRegister register;
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

        addressProvider = IAddressProviderV3(vm.envAddress("FORK_ADDRESS_PROVIDER"));
        acl = ACL(addressProvider.getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL));
        register = ContractsRegister(addressProvider.getAddressOrRevert(AP_CONTRACTS_REGISTER, NO_VERSION_CONTROL));
        configurator = acl.owner();
    }
}
