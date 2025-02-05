// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {IContractsRegister} from "@gearbox-protocol/governance/contracts/interfaces/IContractsRegister.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ICreditConfiguratorLegacy {
    function makeTokenQuoted(address token) external;
}

contract V30Fix is Script {
    address constant ACL = 0x523dA3a8961E4dD4f6206DBf7E6c749f51796bb3;
    address constant CONTRACTS_REGISTER = 0xA50d4E7D8946a7c90652339CDBd262c375d54D99;

    function run() public {
        // Get all credit managers from contracts register
        address[] memory creditManagers = IContractsRegister(CONTRACTS_REGISTER).getCreditManagers();

        address aclOwner = Ownable(ACL).owner();
        _setBalance(aclOwner, 10 ether, "http://127.0.0.1:8545");

        vm.startBroadcast(aclOwner);

        for (uint256 i = 0; i < creditManagers.length; i++) {
            address cm = creditManagers[i];
            uint256 version = IVersion(cm).version();
            if (version < 300 || version >= 3_10) continue;

            ICreditManagerV3 creditManager = ICreditManagerV3(cm);
            address configurator = creditManager.creditConfigurator();

            uint256 tokensCount = creditManager.collateralTokensCount();
            uint256 quotedTokensMask = creditManager.quotedTokensMask();

            for (uint256 j = 1; j < tokensCount; j++) {
                uint256 tokenMask = 1 << j;
                if (quotedTokensMask & tokenMask != 0) continue;
                address token = creditManager.getTokenByMask(tokenMask);

                console.log("Making token quoted:", token);
                ICreditConfiguratorLegacy(configurator).makeTokenQuoted(token);
            }
        }

        vm.stopBroadcast();
    }

    function _setBalance(address account, uint256 balance, string memory forkRpcUrl) internal {
        string[] memory inputs = new string[](7);
        inputs[0] = "cast";
        inputs[1] = "rpc";
        inputs[2] = "anvil_setBalance";
        inputs[3] = vm.toString(account);
        inputs[4] = vm.toString(balance);
        inputs[5] = "--rpc-url";
        inputs[6] = forkRpcUrl;
        vm.ffi(inputs);
    }
}
