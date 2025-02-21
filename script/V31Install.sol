// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";

import {LibString} from "@solady/utils/LibString.sol";

import {IAddressProvider} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProvider.sol";
import {IMarketConfigurator} from "@gearbox-protocol/governance/contracts/interfaces/IMarketConfigurator.sol";
import {IMarketConfiguratorFactory} from
    "@gearbox-protocol/governance/contracts/interfaces/IMarketConfiguratorFactory.sol";
import {CrossChainCall} from "@gearbox-protocol/governance/contracts/interfaces/Types.sol";
import {
    AP_MARKET_CONFIGURATOR_FACTORY,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/governance/contracts/libraries/ContractLiterals.sol";
import {
    GlobalSetup,
    UploadableContract,
    DeploySystemContractCall
} from "@gearbox-protocol/governance/contracts/test/helpers/GlobalSetup.sol";

import {AdapterCompressor} from "../contracts/compressors/AdapterCompressor.sol";
import {CreditAccountCompressor} from "../contracts/compressors/CreditAccountCompressor.sol";
import {CreditSuiteCompressor} from "../contracts/compressors/CreditSuiteCompressor.sol";
import {GaugeCompressor} from "../contracts/compressors/GaugeCompressor.sol";
import {MarketCompressor} from "../contracts/compressors/MarketCompressor.sol";
import {PeripheryCompressor} from "../contracts/compressors/PeripheryCompressor.sol";
import {PoolCompressor} from "../contracts/compressors/PoolCompressor.sol";
import {PriceFeedCompressor} from "../contracts/compressors/PriceFeedCompressor.sol";
import {RewardsCompressor} from "../contracts/compressors/RewardsCompressor.sol";
import {TokenCompressor} from "../contracts/compressors/TokenCompressor.sol";

import {
    AP_ADAPTER_COMPRESSOR,
    AP_CREDIT_ACCOUNT_COMPRESSOR,
    AP_CREDIT_SUITE_COMPRESSOR,
    AP_GAUGE_COMPRESSOR,
    AP_MARKET_COMPRESSOR,
    AP_PERIPHERY_COMPRESSOR,
    AP_POOL_COMPRESSOR,
    AP_PRICE_FEED_COMPRESSOR,
    AP_REWARDS_COMPRESSOR,
    AP_TOKEN_COMPRESSOR
} from "../contracts/libraries/Literals.sol";

import {AnvilHelper} from "./AnvilHelper.sol";
import {LegacyHelper} from "./LegacyHelper.sol";

contract V31Install is Script, GlobalSetup, AnvilHelper, LegacyHelper {
    using LibString for string;

    constructor() GlobalSetup() {
        _autoImpersonate(false);
    }

    function run() public {
        if (block.chainid != 1) return;

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        _fundActors();
        _setUpGlobalContracts();
        _setUpPeripheryContracts();

        // set legacy addresses
        CrossChainCall[] memory calls = _getSetLegacyAddressCalls(address(instanceManager));
        _submitBatchAndSign("Set legacy addresses", calls);

        // activate instances
        for (uint256 i; i < chains.length; ++i) {
            CrossChainCall[] memory activateCalls =
                _getActivateInstanceCalls(address(instanceManager), instanceOwner, chains[i]);
            _submitBatchAndSign(string.concat("Activate instance on ", chains[i].name), activateCalls);
        }

        // connect legacy market configurators
        address addressProvider = instanceManager.addressProvider();
        address factory =
            IAddressProvider(addressProvider).getAddressOrRevert(AP_MARKET_CONFIGURATOR_FACTORY, NO_VERSION_CONTROL);

        bool connectChaosLabs = vm.envOr("CONNECT_CHAOS_LABS", true);
        bool connectNexo = vm.envOr("CONNECT_NEXO", false);
        for (uint256 i; i < curators.length; ++i) {
            if (curators[i].name.eq("Chaos Labs") && !connectChaosLabs) continue;
            if (curators[i].name.eq("Nexo") && !connectNexo) continue;

            if (curators[i].chainId == 1) _deployLegacyMarketConfigurator(addressProvider, curators[i]);

            CrossChainCall[] memory addCalls =
                _getAddLegacyMarketConfiguratorCalls(addressProvider, factory, curators[i]);
            _submitBatchAndSign(
                string.concat(
                    "Add legacy market configurator for ", curators[i].name, " on ", _getChainName(curators[i].chainId)
                ),
                addCalls
            );
        }

        vm.stopBroadcast();

        _saveAddresses(vm.envOr("OUT_DIR", string(".")));
    }

    function deployLegacyMarketConfigurators() public {
        if (block.chainid == 1) return;

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        _attachGlobalContracts();

        address addressProvider = instanceManager.addressProvider();
        bool connectChaosLabs = vm.envOr("CONNECT_CHAOS_LABS", true);
        bool connectNexo = vm.envOr("CONNECT_NEXO", false);
        for (uint256 i; i < curators.length; ++i) {
            if (curators[i].name.eq("Chaos Labs") && !connectChaosLabs) continue;
            if (curators[i].name.eq("Nexo") && !connectNexo) continue;

            if (curators[i].chainId == block.chainid) _deployLegacyMarketConfigurator(addressProvider, curators[i]);
        }

        vm.stopBroadcast();
    }

    function _setUpPeripheryContracts() internal {
        // Upload bytecode to the bytecode repository
        UploadableContract[10] memory peripheryContracts = [
            UploadableContract({
                initCode: type(TokenCompressor).creationCode,
                contractType: AP_TOKEN_COMPRESSOR,
                version: 3_10
            }),
            UploadableContract({
                initCode: type(CreditAccountCompressor).creationCode,
                contractType: AP_CREDIT_ACCOUNT_COMPRESSOR,
                version: 3_10
            }),
            UploadableContract({
                initCode: type(PriceFeedCompressor).creationCode,
                contractType: AP_PRICE_FEED_COMPRESSOR,
                version: 3_10
            }),
            UploadableContract({
                initCode: type(CreditSuiteCompressor).creationCode,
                contractType: AP_CREDIT_SUITE_COMPRESSOR,
                version: 3_10
            }),
            UploadableContract({
                initCode: type(PoolCompressor).creationCode,
                contractType: AP_POOL_COMPRESSOR,
                version: 3_10
            }),
            UploadableContract({
                initCode: type(MarketCompressor).creationCode,
                contractType: AP_MARKET_COMPRESSOR,
                version: 3_10
            }),
            UploadableContract({
                initCode: type(PeripheryCompressor).creationCode,
                contractType: AP_PERIPHERY_COMPRESSOR,
                version: 3_10
            }),
            UploadableContract({
                initCode: type(RewardsCompressor).creationCode,
                contractType: AP_REWARDS_COMPRESSOR,
                version: 3_10
            }),
            UploadableContract({
                initCode: type(AdapterCompressor).creationCode,
                contractType: AP_ADAPTER_COMPRESSOR,
                version: 3_10
            }),
            UploadableContract({
                initCode: type(GaugeCompressor).creationCode,
                contractType: AP_GAUGE_COMPRESSOR,
                version: 3_10
            })
        ];

        uint256 len = peripheryContracts.length;
        CrossChainCall[] memory calls = new CrossChainCall[](len);
        for (uint256 i = 0; i < len; ++i) {
            bytes32 bytecodeHash = _uploadByteCodeAndSign(
                peripheryContracts[i].initCode, peripheryContracts[i].contractType, peripheryContracts[i].version
            );
            calls[i] = _generateAllowSystemContractCall(bytecodeHash);
        }

        _submitBatchAndSign("Allow periphery system contracts", calls);

        // Deploy periphery contracts
        DeploySystemContractCall[10] memory deployCalls = [
            DeploySystemContractCall({contractType: AP_TOKEN_COMPRESSOR, version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: AP_CREDIT_ACCOUNT_COMPRESSOR, version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: AP_PRICE_FEED_COMPRESSOR, version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: AP_CREDIT_SUITE_COMPRESSOR, version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: AP_POOL_COMPRESSOR, version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: AP_MARKET_COMPRESSOR, version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: AP_PERIPHERY_COMPRESSOR, version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: AP_REWARDS_COMPRESSOR, version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: AP_ADAPTER_COMPRESSOR, version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: AP_GAUGE_COMPRESSOR, version: 3_10, saveVersion: true})
        ];

        len = deployCalls.length;
        calls = new CrossChainCall[](len);
        for (uint256 i = 0; i < len; ++i) {
            calls[i] = _generateDeploySystemContractCall(
                deployCalls[i].contractType, deployCalls[i].version, deployCalls[i].saveVersion
            );
        }

        _submitBatchAndSign("Deploy periphery system contracts", calls);
    }

    function _saveAddresses(string memory path) internal {
        address addressProvider = instanceManager.addressProvider();

        string memory json = vm.serializeAddress("addresses", "instanceManager", address(instanceManager));
        json = vm.serializeAddress("addresses", "bytecodeRepository", address(bytecodeRepository));
        json = vm.serializeAddress("addresses", "multisig", address(multisig));
        json = vm.serializeAddress("addresses", "addressProvider", addressProvider);

        address marketConfiguratorFactory =
            IAddressProvider(addressProvider).getAddressOrRevert(AP_MARKET_CONFIGURATOR_FACTORY, NO_VERSION_CONTROL);
        address[] memory marketConfigurators =
            IMarketConfiguratorFactory(marketConfiguratorFactory).getMarketConfigurators();
        for (uint256 i; i < marketConfigurators.length; ++i) {
            json = vm.serializeAddress(
                "addresses",
                string.concat(
                    "market-configurator-",
                    vm.replace(vm.toLowercase(IMarketConfigurator(marketConfigurators[i]).curatorName()), " ", "-")
                ),
                marketConfigurators[i]
            );
        }

        vm.writeJson(json, string.concat(path, "/addresses.json"));
    }
}
