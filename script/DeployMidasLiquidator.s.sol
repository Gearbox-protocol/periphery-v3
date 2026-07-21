// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";

import {MidasLiquidator} from "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasLiquidator.sol";

import {SecuritizeAttachHelper} from "../contracts/test/attach/securitize/SecuritizeAttachHelper.sol";

contract DeployMidasLiquidator is Script, SecuritizeAttachHelper {
    function run() external {
        vm.skip(ADDRESS_PROVIDER.code.length == 0, "Not in an attach mode");
        vm.skip(block.chainid != 1, "Not Ethereum mainnet");
        // NOTE: even though we compile our contracts under Shanghai EVM version,
        // more recent one is usually needed to interact with third-party contracts
        vm.setEvmVersion("osaka");

        uint256 authorPrivateKey = vm.envOr("AUTHOR_PRIVATE_KEY", uint256(0));
        require(authorPrivateKey != 0, "AUTHOR_PRIVATE_KEY is not set");
        deployer = author = auditor = riskCurator = vm.createWallet(authorPrivateKey);

        _attachCore();
        _addAuditor(auditor.addr, "Fake Auditor");
        _addPublicDomain("RWA_LIQUIDATOR");

        _uploadContract("RWA_LIQUIDATOR::MIDAS", 3_11, type(MidasLiquidator).creationCode);
        address midasLiquidator = _deploy("RWA_LIQUIDATOR::MIDAS", 3_11, "");

        string memory json;
        json = vm.serializeAddress("MidasAddresses", "midasLiquidator", midasLiquidator);
        vm.writeJson(json, string.concat(vm.envOr("OUTPUT_DIR", string(".")), "/midas-addresses.json"));
    }
}
