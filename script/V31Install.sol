// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {PriceFeedCompressor} from "../contracts/compressors/PriceFeedCompressor.sol";
import {TokenCompressor} from "../contracts/compressors/TokenCompressor.sol";
import {MarketCompressor} from "../contracts/compressors/MarketCompressor.sol";
import {CreditAccountCompressor} from "../contracts/compressors/CreditAccountCompressor.sol";
import {PoolCompressor} from "../contracts/compressors/PoolCompressor.sol";
import {CreditSuiteCompressor} from "../contracts/compressors/CreditSuiteCompressor.sol";
import {Script} from "forge-std/Script.sol";

import {
    UploadableContract,
    DeploySystemContractCall
} from "@gearbox-protocol/governance/contracts/test/helpers/GlobalSetup.sol";

import {CrossChainCall} from "@gearbox-protocol/governance/contracts/interfaces/Types.sol";
import {
    AP_ACL,
    AP_BOT_LIST,
    AP_CONTRACTS_REGISTER,
    AP_DEGEN_DISTRIBUTOR,
    AP_DEGEN_NFT,
    AP_GEAR_STAKING,
    AP_GEAR_TOKEN,
    AP_INFLATION_ATTACK_BLOCKER,
    AP_MARKET_CONFIGURATOR_FACTORY,
    AP_MULTI_PAUSE,
    AP_ROUTER,
    AP_TREASURY,
    AP_WETH_TOKEN,
    AP_ZAPPER_REGISTER,
    AP_ZERO_PRICE_FEED,
    AP_TREASURY,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/governance/contracts/libraries/ContractLiterals.sol";

import {
    AP_MARKET_COMPRESSOR,
    AP_POOL_COMPRESSOR,
    AP_TOKEN_COMPRESSOR,
    AP_PRICE_FEED_COMPRESSOR,
    AP_CREDIT_ACCOUNT_COMPRESSOR,
    AP_CREDIT_SUITE_COMPRESSOR
} from "../contracts/libraries/Literals.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {GlobalSetup} from "@gearbox-protocol/governance/contracts/test/helpers/GlobalSetup.sol";
import {console} from "forge-std/console.sol";
import {InstanceManager} from "@gearbox-protocol/governance/contracts/instance/InstanceManager.sol";

struct APMigration {
    bytes32 name;
    uint256 version;
}

interface IAddressProviderLegacy {
    function getAddressOrRevert(bytes32 key, uint256 version) external view returns (address);
}

contract V31Install is Script, GlobalSetup {
    using LibString for bytes32;

    constructor() GlobalSetup() {
        _setPeripheryContracts();
    }

    function run() public {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _fundActors();

        _setUpGlobalContracts();

        DeploySystemContractCall[6] memory deployCalls = [
            DeploySystemContractCall({contractType: "TOKEN_COMPRESSOR", version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: "CREDIT_ACCOUNT_COMPRESSOR", version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: "PRICE_FEED_COMPRESSOR", version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: "CREDIT_SUITE_COMPRESSOR", version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: "POOL_COMPRESSOR", version: 3_10, saveVersion: true}),
            DeploySystemContractCall({contractType: "MARKET_COMPRESSOR", version: 3_10, saveVersion: true})
        ];

        uint256 len = deployCalls.length;

        CrossChainCall[] memory calls = new CrossChainCall[](len);
        for (uint256 i = 0; i < len; ++i) {
            calls[i] = _generateDeploySystemContractCall(
                deployCalls[i].contractType, deployCalls[i].version, deployCalls[i].saveVersion
            );
        }

        _submitProposalAndSign("Deploy periphery contracts", calls);

        (address gear, address weth, address treasury) = _connectLegacyContracts();

        calls = new CrossChainCall[](1);
        calls[0] = _generateActivateCall({
            _chainId: block.chainid,
            _instanceOwner: instanceOwner,
            _treasury: treasury,
            _weth: weth,
            _gear: gear
        });

        _submitProposalAndSign("Activate instance", calls);

        vm.stopBroadcast();

        _exportJson();
    }

    function _connectLegacyContracts() internal returns (address gear, address weth, address treasury) {
        address addressProviderLegacy = vm.envAddress("ADDRESS_PROVIDER_LEGACY");

        APMigration[16] memory migrations = [
            APMigration({name: "ACCOUNT_FACTORY", version: 0}),
            APMigration({name: AP_BOT_LIST, version: 300}),
            APMigration({name: AP_DEGEN_DISTRIBUTOR, version: 0}),
            APMigration({name: AP_DEGEN_NFT, version: 1}),
            APMigration({name: AP_GEAR_STAKING, version: 300}),
            APMigration({name: AP_GEAR_TOKEN, version: 0}),
            APMigration({name: AP_INFLATION_ATTACK_BLOCKER, version: 300}),
            APMigration({name: AP_MULTI_PAUSE, version: 0}),
            APMigration({name: AP_ROUTER, version: 302}),
            APMigration({name: AP_WETH_TOKEN, version: 0}),
            APMigration({name: AP_ZAPPER_REGISTER, version: 300}),
            APMigration({name: AP_ZERO_PRICE_FEED, version: 0}),
            APMigration({name: "PARTIAL_LIQUIDATION_BOT", version: 300}),
            APMigration({name: "DELEVERAGE_BOT_PEGGED", version: 300}),
            APMigration({name: "DELEVERAGE_BOT_LV", version: 300}),
            APMigration({name: "DELEVERAGE_BOT_HV", version: 300})
        ];

        uint256 len = migrations.length;

        CrossChainCall[] memory calls = new CrossChainCall[](len);
        for (uint256 i; i < len; ++i) {
            string memory key = migrations[i].name.fromSmallString();

            try IAddressProviderLegacy(addressProviderLegacy).getAddressOrRevert(
                migrations[i].name, migrations[i].version
            ) returns (address oldAddress) {
                console.log("migrating", key, oldAddress);
                calls[i] = CrossChainCall({
                    chainId: block.chainid,
                    target: address(instanceManager),
                    callData: abi.encodeCall(
                        InstanceManager.setLegacyAddress, (key, oldAddress, migrations[i].version != 0)
                    )
                });
            } catch {
                console.log("Failed to migrate", key);
            }
        }

        _submitProposalAndSign("Migrate legacy contracts", calls);

        gear = IAddressProviderLegacy(addressProviderLegacy).getAddressOrRevert(AP_GEAR_TOKEN, 0);
        weth = IAddressProviderLegacy(addressProviderLegacy).getAddressOrRevert(AP_WETH_TOKEN, 0);
        treasury = IAddressProviderLegacy(addressProviderLegacy).getAddressOrRevert(AP_TREASURY, 0);
    }

    function _setPeripheryContracts() internal {
        contractsToUpload.push(
            UploadableContract({
                initCode: type(TokenCompressor).creationCode,
                contractType: AP_TOKEN_COMPRESSOR,
                version: 3_10
            })
        );
        contractsToUpload.push(
            UploadableContract({
                initCode: type(CreditAccountCompressor).creationCode,
                contractType: AP_CREDIT_ACCOUNT_COMPRESSOR,
                version: 3_10
            })
        );

        contractsToUpload.push(
            UploadableContract({
                initCode: type(PriceFeedCompressor).creationCode,
                contractType: AP_PRICE_FEED_COMPRESSOR,
                version: 3_10
            })
        );

        contractsToUpload.push(
            UploadableContract({
                initCode: type(CreditSuiteCompressor).creationCode,
                contractType: AP_CREDIT_SUITE_COMPRESSOR,
                version: 3_10
            })
        );

        contractsToUpload.push(
            UploadableContract({
                initCode: type(PoolCompressor).creationCode,
                contractType: AP_POOL_COMPRESSOR,
                version: 3_10
            })
        );

        contractsToUpload.push(
            UploadableContract({
                initCode: type(MarketCompressor).creationCode,
                contractType: AP_MARKET_COMPRESSOR,
                version: 3_10
            })
        );
    }
}
