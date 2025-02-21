// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {LibString} from "@solady/utils/LibString.sol";

import {AdapterCompressor} from "../contracts/compressors/AdapterCompressor.sol";
import {GaugeCompressor} from "../contracts/compressors/GaugeCompressor.sol";
import {PriceFeedCompressor} from "../contracts/compressors/PriceFeedCompressor.sol";
import {TokenCompressor} from "../contracts/compressors/TokenCompressor.sol";
import {MarketCompressor} from "../contracts/compressors/MarketCompressor.sol";
import {CreditAccountCompressor} from "../contracts/compressors/CreditAccountCompressor.sol";
import {PoolCompressor} from "../contracts/compressors/PoolCompressor.sol";
import {CreditSuiteCompressor} from "../contracts/compressors/CreditSuiteCompressor.sol";
import {PeripheryCompressor} from "../contracts/compressors/PeripheryCompressor.sol";
import {RewardsCompressor} from "../contracts/compressors/RewardsCompressor.sol";

import {
    GlobalSetup,
    UploadableContract,
    DeploySystemContractCall
} from "@gearbox-protocol/governance/contracts/test/helpers/GlobalSetup.sol";

import {CrossChainCall} from "@gearbox-protocol/governance/contracts/interfaces/Types.sol";
import {
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
    AP_ADAPTER_COMPRESSOR,
    AP_GAUGE_COMPRESSOR,
    AP_MARKET_COMPRESSOR,
    AP_POOL_COMPRESSOR,
    AP_TOKEN_COMPRESSOR,
    AP_PRICE_FEED_COMPRESSOR,
    AP_CREDIT_ACCOUNT_COMPRESSOR,
    AP_CREDIT_SUITE_COMPRESSOR,
    AP_PERIPHERY_COMPRESSOR,
    AP_REWARDS_COMPRESSOR
} from "../contracts/libraries/Literals.sol";

import {InstanceManager} from "@gearbox-protocol/governance/contracts/instance/InstanceManager.sol";
import {
    LegacyParams,
    MarketConfiguratorLegacy
} from "@gearbox-protocol/governance/contracts/market/legacy/MarketConfiguratorLegacy.sol";
import {IAddressProvider} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProvider.sol";
import {IContractsRegister} from "@gearbox-protocol/governance/contracts/interfaces/IContractsRegister.sol";
import {IMarketConfiguratorFactory} from
    "@gearbox-protocol/governance/contracts/interfaces/IMarketConfiguratorFactory.sol";
import {IMarketConfigurator} from "@gearbox-protocol/governance/contracts/interfaces/IMarketConfigurator.sol";

import {AnvilHelper} from "./AnvilHelper.sol";

struct APMigration {
    bytes32 name;
    uint256 version;
}

interface IAddressProviderLegacy {
    function getAddressOrRevert(bytes32 key, uint256 version) external view returns (address);
}

contract V31Install is Script, GlobalSetup, AnvilHelper {
    using LibString for bytes32;

    constructor() GlobalSetup() {
        _setPeripheryContracts();
        _autoImpersonate(false);
    }

    function run() public {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        _fundActors();

        _setUpGlobalContracts();

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

        uint256 len = deployCalls.length;

        CrossChainCall[] memory calls = new CrossChainCall[](len);
        for (uint256 i = 0; i < len; ++i) {
            calls[i] = _generateDeploySystemContractCall(
                deployCalls[i].contractType, deployCalls[i].version, deployCalls[i].saveVersion
            );
        }

        _submitBatchAndSign("Deploy periphery contracts", calls);

        (address gear, address weth, address treasury) = _connectLegacyContracts();

        calls = new CrossChainCall[](1);
        calls[0] = _generateActivateCall({
            _chainId: block.chainid,
            _instanceOwner: instanceOwner,
            _treasury: treasury,
            _weth: weth,
            _gear: gear
        });

        _submitBatchAndSign("Activate instance", calls);

        if (vm.envOr("CONNECT_CHAOS_LABS", true)) {
            _connectLegacyMarketConfigurator("Chaos Labs", _getChaosLabsMainnetLegacyParams());
        }
        if (vm.envOr("CONNECT_NEXO", false)) {
            _connectLegacyMarketConfigurator("Nexo", _getNexoMainnetLegacyParams());
        }

        vm.stopBroadcast();

        _saveAddresses(vm.envOr("OUT_DIR", string(".")));
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

        _submitBatchAndSign("Migrate legacy contracts", calls);

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

        contractsToUpload.push(
            UploadableContract({
                initCode: type(PeripheryCompressor).creationCode,
                contractType: AP_PERIPHERY_COMPRESSOR,
                version: 3_10
            })
        );

        contractsToUpload.push(
            UploadableContract({
                initCode: type(RewardsCompressor).creationCode,
                contractType: AP_REWARDS_COMPRESSOR,
                version: 3_10
            })
        );

        contractsToUpload.push(
            UploadableContract({
                initCode: type(AdapterCompressor).creationCode,
                contractType: AP_ADAPTER_COMPRESSOR,
                version: 3_10
            })
        );

        contractsToUpload.push(
            UploadableContract({
                initCode: type(GaugeCompressor).creationCode,
                contractType: AP_GAUGE_COMPRESSOR,
                version: 3_10
            })
        );
    }

    function _connectLegacyMarketConfigurator(string memory curatorName, LegacyParams memory legacyParams) internal {
        address addressProvider = instanceManager.addressProvider();

        MarketConfiguratorLegacy marketConfigurator = new MarketConfiguratorLegacy({
            addressProvider_: addressProvider,
            // QUESTION: who?
            admin_: address(0),
            emergencyAdmin_: address(0),
            curatorName_: curatorName,
            deployGovernor_: false, // NOTE: only for testing
            legacyParams_: legacyParams
        });

        address contractsRegister = marketConfigurator.contractsRegister();
        address[] memory pools = IContractsRegister(contractsRegister).getPools();
        uint256 numPools = pools.length;
        for (uint256 i; i < numPools; ++i) {
            address pool = pools[i];
            marketConfigurator.initializeMarket(pool);
        }
        address[] memory creditManagers = IContractsRegister(contractsRegister).getCreditManagers();
        uint256 numCreditManagers = creditManagers.length;
        for (uint256 i; i < numCreditManagers; ++i) {
            address creditManager = creditManagers[i];
            marketConfigurator.initializeCreditSuite(creditManager);
        }

        // TODO: will need to transfer ACL ownership and call `marketConfigurator.finalizeMigration()`

        address marketConfiguratorFactory =
            IAddressProvider(addressProvider).getAddressOrRevert(AP_MARKET_CONFIGURATOR_FACTORY, NO_VERSION_CONTROL);
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = CrossChainCall({
            chainId: block.chainid,
            target: address(marketConfiguratorFactory),
            callData: abi.encodeCall(IMarketConfiguratorFactory.addMarketConfigurator, (address(marketConfigurator)))
        });

        _submitBatchAndSign(string.concat("Connect legacy market configurator for ", curatorName), calls);
    }

    function _getChaosLabsMainnetLegacyParams() internal pure returns (LegacyParams memory) {
        // NOTE: when writing an actual migration script, make sure to check that all values are correct,
        // don't just copy-paste from here
        address acl = 0x523dA3a8961E4dD4f6206DBf7E6c749f51796bb3;
        address contractsRegister = 0xA50d4E7D8946a7c90652339CDBd262c375d54D99;
        address gearStaking = 0x2fcbD02d5B1D52FC78d4c02890D7f4f47a459c33;
        address zapperRegister = 0x3E75276548a7722AbA517a35c35FB43CF3B0E723;

        address[] memory pausableAdmins = new address[](16);
        pausableAdmins[0] = 0xA7D5DDc1b8557914F158076b228AA91eF613f1D5;
        pausableAdmins[1] = 0x65b384cEcb12527Da51d52f15b4140ED7FaD7308;
        pausableAdmins[2] = 0xD7b069517246edB58Ce670485b4931E0a86Ab6Ff;
        pausableAdmins[3] = 0xD5C96E5c1E1C84dFD293473fC195BbE7FC8E4840;
        pausableAdmins[4] = 0xa133C9A92Fb8dDB962Af1cbae58b2723A0bdf23b;
        pausableAdmins[5] = 0xd4fe3eD38250C38A0094224C4B0224b5D5d0e7d9;
        pausableAdmins[6] = 0x8d2f33d168cca6D2436De16c27d3f1cEa30aC245;
        pausableAdmins[7] = 0x67479449b2cf25AEE2fB6EF6f0aEc54591154F62;
        pausableAdmins[8] = 0x4Ae3EDbDf1C42e3560Cc2D52B8F353F026F67b44;
        pausableAdmins[9] = 0x700De428aa940000259B1c58F3E44445d360303c;
        pausableAdmins[10] = 0xf4ecc4e950b563F113b17C5606B31a314B99BFe3;
        pausableAdmins[11] = 0xFaCADE00dc661bfBE736e2F0f72b4Ee59017d5fb;
        pausableAdmins[12] = 0xc9E3453E212A13169AaA66aa39DCcE82aE6966B7;
        pausableAdmins[13] = 0x34EE4eed88BCd2B5cDC3eF9A9DD0582EE538E541;
        pausableAdmins[14] = 0x3F185f4ec14fCfB522bC499d790a9608A05E64F6;
        pausableAdmins[15] = 0xbb803559B4D58b75E12dd74641AB955e8B0Df40E;

        address[] memory unpausableAdmins = new address[](3);
        unpausableAdmins[0] = 0xA7D5DDc1b8557914F158076b228AA91eF613f1D5;
        unpausableAdmins[1] = 0xbb803559B4D58b75E12dd74641AB955e8B0Df40E;
        unpausableAdmins[2] = 0xa133C9A92Fb8dDB962Af1cbae58b2723A0bdf23b;

        address[] memory emergencyLiquidators = new address[](2);
        emergencyLiquidators[0] = 0x7BD9c8161836b1F402233E80F55E3CaE0Fde4d87;
        emergencyLiquidators[1] = 0x16040e932b5Ac7A3aB23b88a2f230B4185727b0d;

        // NOTE: these are the PL bot (the only one with special permissions) and three deleverage bots
        address[] memory bots = new address[](4);
        bots[0] = 0x0f06c2bD612Ee7D52d4bC76Ce3BD7E95247AF2a9;
        bots[1] = 0x53fDA9a509020Fc534EfF938Fd01dDa5fFe8560c;
        bots[2] = 0x82b0adfA8f09b20BB4ed066Bcd4b2a84BEf73D5E;
        bots[3] = 0x519906cD00222b4a81bf14A7A11fA5FCF455Af42;

        return LegacyParams({
            acl: acl,
            contractsRegister: contractsRegister,
            gearStaking: gearStaking,
            zapperRegister: zapperRegister,
            pausableAdmins: pausableAdmins,
            unpausableAdmins: unpausableAdmins,
            emergencyLiquidators: emergencyLiquidators,
            bots: bots
        });
    }

    function _getChaosLabsOptimismLegacyParams() internal pure returns (LegacyParams memory) {
        address acl = 0x6a2994Af133e0F87D9b665bFCe821dC917e8347D;
        address contractsRegister = 0x949F9899bDaDcC7831Ca422f115fe61f4211a30b;
        address gearStaking = 0x8D2622f1CA3B42b637e2ff6753E6b69D3ab9Adfd;
        address zapperRegister = 0x5f49A919d67378290f5aeb359928E0020cD90Bae;

        address[] memory pausableAdmins = new address[](6);
        pausableAdmins[0] = 0x148DD932eCe1155c11006F5650c6Ff428f8D374A;
        pausableAdmins[1] = 0x44c01002ef0955A4DBD86D90dDD27De6eeE37aA3;
        pausableAdmins[2] = 0x65b384cEcb12527Da51d52f15b4140ED7FaD7308;
        pausableAdmins[3] = 0xD5C96E5c1E1C84dFD293473fC195BbE7FC8E4840;
        pausableAdmins[4] = 0x8bA8cd6D00919ceCc19D9B4A2c8669a524883C4c;
        pausableAdmins[5] = 0x9744f76dc5239Eb4DC2CE8D5538e1BA89C8FA90f;

        address[] memory unpausableAdmins = new address[](4);
        unpausableAdmins[0] = 0x148DD932eCe1155c11006F5650c6Ff428f8D374A;
        unpausableAdmins[1] = 0x44c01002ef0955A4DBD86D90dDD27De6eeE37aA3;
        unpausableAdmins[2] = 0x8bA8cd6D00919ceCc19D9B4A2c8669a524883C4c;
        unpausableAdmins[3] = 0x9744f76dc5239Eb4DC2CE8D5538e1BA89C8FA90f;

        address[] memory emergencyLiquidators = new address[](2);
        emergencyLiquidators[0] = 0x7BD9c8161836b1F402233E80F55E3CaE0Fde4d87;
        emergencyLiquidators[1] = 0x16040e932b5Ac7A3aB23b88a2f230B4185727b0d;

        address[] memory bots = new address[](4);
        bots[0] = 0x0A12a15F359FdefD36c9fA8bd3193940A8B344eF;
        bots[1] = 0x383562873F3c3A75ec5CEC6F9b91B5F04d44465c;
        bots[2] = 0x7B84Db149430fbB158c67E0F08B162a746A757bd;
        bots[3] = 0x08952Ea9cEA25781C5b7F9B5fD8a534aC614DD37;

        return LegacyParams({
            acl: acl,
            contractsRegister: contractsRegister,
            gearStaking: gearStaking,
            zapperRegister: zapperRegister,
            pausableAdmins: pausableAdmins,
            unpausableAdmins: unpausableAdmins,
            emergencyLiquidators: emergencyLiquidators,
            bots: bots
        });
    }

    function _getChaosLabsArbitrumLegacyParams() internal pure returns (LegacyParams memory) {
        address acl = 0xb2FA6c1a629Ed72BF99fbB24f75E5D130A5586F1;
        address contractsRegister = 0xc3e00cdA97D5779BFC8f17588d55b4544C8a6c47;
        address gearStaking = 0xf3599BEfe8E79169Afd5f0b7eb0A1aA322F193D9;
        address zapperRegister = 0xFFadb168E3ACB881DE164aDdfc77d92dbc2D4C16;

        address[] memory pausableAdmins = new address[](5);
        pausableAdmins[0] = 0x148DD932eCe1155c11006F5650c6Ff428f8D374A;
        pausableAdmins[1] = 0xf9E344ADa2181A4104a7DC6092A92A1bC67A52c9;
        pausableAdmins[2] = 0x65b384cEcb12527Da51d52f15b4140ED7FaD7308;
        pausableAdmins[3] = 0xD5C96E5c1E1C84dFD293473fC195BbE7FC8E4840;
        pausableAdmins[4] = 0x746fb3AcAfF6Bfe246206EC2E51F587d2E57abb6;

        address[] memory unpausableAdmins = new address[](3);
        unpausableAdmins[0] = 0x148DD932eCe1155c11006F5650c6Ff428f8D374A;
        unpausableAdmins[1] = 0xf9E344ADa2181A4104a7DC6092A92A1bC67A52c9;
        unpausableAdmins[2] = 0x746fb3AcAfF6Bfe246206EC2E51F587d2E57abb6;

        address[] memory emergencyLiquidators = new address[](2);
        emergencyLiquidators[0] = 0x7BD9c8161836b1F402233E80F55E3CaE0Fde4d87;
        emergencyLiquidators[1] = 0x16040e932b5Ac7A3aB23b88a2f230B4185727b0d;

        address[] memory bots = new address[](4);
        bots[0] = 0x938094B41dDaC7bD3f21fC962D424E1a84ac4a85;
        bots[1] = 0x44A9fDEF7307AE8C0997a1A339588a1C073930a7;
        bots[2] = 0x8A35C229ff4f96e8b7A4f9168B22b9F7DF6b82f3;
        bots[3] = 0x538d66d6cA2607673ceC8af3cA3933476f361633;

        return LegacyParams({
            acl: acl,
            contractsRegister: contractsRegister,
            gearStaking: gearStaking,
            zapperRegister: zapperRegister,
            pausableAdmins: pausableAdmins,
            unpausableAdmins: unpausableAdmins,
            emergencyLiquidators: emergencyLiquidators,
            bots: bots
        });
    }

    function _getNexoMainnetLegacyParams() internal pure returns (LegacyParams memory) {
        address acl = 0xd98D75da123813D73c54bCF910BBd7FC0afF24d4;
        address contractsRegister = 0xFC1952052dC1f439ccF0cBd9af5A02748b0cc1db;
        address gearStaking = 0x2fcbD02d5B1D52FC78d4c02890D7f4f47a459c33;
        address zapperRegister = 0x3E75276548a7722AbA517a35c35FB43CF3B0E723;

        // TODO: add proper values
        address[] memory pausableAdmins = new address[](0);
        // pausableAdmins[0] = 0xD5C96E5c1E1C84dFD293473fC195BbE7FC8E4840;

        address[] memory unpausableAdmins = new address[](0);
        // unpausableAdmins[0] = 0xD5C96E5c1E1C84dFD293473fC195BbE7FC8E4840;

        address[] memory emergencyLiquidators = new address[](0);
        // emergencyLiquidators[0] = 0x7BD9c8161836b1F402233E80F55E3CaE0Fde4d87;
        // emergencyLiquidators[1] = 0x16040e932b5Ac7A3aB23b88a2f230B4185727b0d;

        // NOTE: these are the PL bot (the only one with special permissions) and three deleverage bots
        address[] memory bots = new address[](4);
        bots[0] = 0x0f06c2bD612Ee7D52d4bC76Ce3BD7E95247AF2a9;
        bots[1] = 0x53fDA9a509020Fc534EfF938Fd01dDa5fFe8560c;
        bots[2] = 0x82b0adfA8f09b20BB4ed066Bcd4b2a84BEf73D5E;
        bots[3] = 0x519906cD00222b4a81bf14A7A11fA5FCF455Af42;

        return LegacyParams({
            acl: acl,
            contractsRegister: contractsRegister,
            gearStaking: gearStaking,
            zapperRegister: zapperRegister,
            pausableAdmins: pausableAdmins,
            unpausableAdmins: unpausableAdmins,
            emergencyLiquidators: emergencyLiquidators,
            bots: bots
        });
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
