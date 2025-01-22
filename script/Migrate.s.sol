// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.17;

// import {Script} from "forge-std/Script.sol";
// import {console} from "forge-std/console.sol";

// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// import {LibString} from "@solady/utils/LibString.sol";

// import {AddressProvider} from "@gearbox-protocol/governance/contracts/global/AddressProvider.sol";
// import {IACL} from "@gearbox-protocol/governance/contracts/interfaces/extensions/IACL.sol";
// import {
//     AP_ACCOUNT_FACTORY,
//     AP_ACL,
//     AP_BOT_LIST,
//     AP_CONTRACTS_REGISTER,
//     AP_DEGEN_DISTRIBUTOR,
//     AP_DEGEN_NFT,
//     AP_GEAR_STAKING,
//     AP_GEAR_TOKEN,
//     AP_INFLATION_ATTACK_BLOCKER,
//     AP_MARKET_CONFIGURATOR_FACTORY,
//     AP_MULTI_PAUSE,
//     AP_ROUTER,
//     AP_TREASURY,
//     AP_WETH_TOKEN,
//     AP_ZAPPER_REGISTER,
//     AP_ZERO_PRICE_FEED,
//     NO_VERSION_CONTROL
// } from "@gearbox-protocol/governance/contracts/libraries/ContractLiterals.sol";

// import {CreditAccountCompressor} from "../contracts/compressors/CreditAccountCompressor.sol";
// import {MarketCompressor} from "../contracts/compressors/MarketCompressor.sol";
// import {PriceFeedCompressor} from "../contracts/compressors/PriceFeedCompressor.sol";

// import {MarketConfigurator} from "../contracts/migration/MarketConfigurator.sol";

// struct APMigration {
//     bytes32 name;
//     uint256 version;
// }

// interface IAddressProviderLegacy {
//     function getAddressOrRevert(bytes32 key, uint256 version) external view returns (address);
// }

// contract MigrateScript is Script {
//     using LibString for bytes32;

//     modifier withBroadcast() {
//         vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
//         _;
//         vm.stopBroadcast();
//     }

//     function run() external withBroadcast {
//         address addressProviderLegacy = vm.envAddress("ADDRESS_PROVIDER");
//         string memory name = vm.envString("CURATOR_NAME");
//         _deployAddressProvider(addressProviderLegacy);
//         _deployMarketConfigurator(addressProviderLegacy, name);
//     }

//     function deployAddressProvider() external withBroadcast {
//         address addressProviderLegacy = vm.envAddress("ADDRESS_PROVIDER");
//         _deployAddressProvider(addressProviderLegacy);
//     }

//     function deployMarketConfigurator() external withBroadcast {
//         address addressProviderLegacy = vm.envAddress("ADDRESS_PROVIDER");
//         string memory name = vm.envString("CURATOR_NAME");
//         _deployMarketConfigurator(addressProviderLegacy, name);
//     }

//     function _deployAddressProvider(address addressProviderLegacy) internal {
//         address acl = IAddressProviderLegacy(addressProviderLegacy).getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL);

//         AddressProvider addressProvider = new AddressProvider();
//         console.log("new address provider:", address(addressProvider));

//         // NOTE: just some fake address
//         addressProvider.setAddress({
//             key: AP_MARKET_CONFIGURATOR_FACTORY.fromSmallString(),
//             value: address(1),
//             saveVersion: false
//         });

//         APMigration[16] memory migrations = [
//             APMigration({name: AP_ACCOUNT_FACTORY, version: 0}),
//             APMigration({name: AP_BOT_LIST, version: 300}),
//             APMigration({name: AP_DEGEN_DISTRIBUTOR, version: 0}),
//             APMigration({name: AP_DEGEN_NFT, version: 1}),
//             APMigration({name: AP_GEAR_STAKING, version: 300}),
//             APMigration({name: AP_GEAR_TOKEN, version: 0}),
//             APMigration({name: AP_INFLATION_ATTACK_BLOCKER, version: 300}),
//             APMigration({name: AP_MULTI_PAUSE, version: 0}),
//             APMigration({name: AP_ROUTER, version: 302}),
//             APMigration({name: AP_WETH_TOKEN, version: 0}),
//             APMigration({name: AP_ZAPPER_REGISTER, version: 300}),
//             APMigration({name: AP_ZERO_PRICE_FEED, version: 0}),
//             APMigration({name: "PARTIAL_LIQUIDATION_BOT", version: 300}),
//             APMigration({name: "DELEVERAGE_BOT_PEGGED", version: 300}),
//             APMigration({name: "DELEVERAGE_BOT_LV", version: 300}),
//             APMigration({name: "DELEVERAGE_BOT_HV", version: 300})
//         ];

//         uint256 len = migrations.length;
//         for (uint256 i; i < len; ++i) {
//             string memory key = migrations[i].name.fromSmallString();

//             try IAddressProviderLegacy(addressProviderLegacy).getAddressOrRevert(
//                 migrations[i].name, migrations[i].version
//             ) returns (address oldAddress) {
//                 console.log("migrating", key, oldAddress);

//                 addressProvider.setAddress({
//                     key: key,
//                     value: oldAddress,
//                     saveVersion: migrations[i].version != NO_VERSION_CONTROL
//                 });
//             } catch {
//                 console.log("Failed to migrate", key);
//             }
//         }

//         address priceFeedCompressor = address(new PriceFeedCompressor());
//         addressProvider.setAddress(priceFeedCompressor, true);

//         address marketCompressor = address(new MarketCompressor(address(addressProvider), priceFeedCompressor));
//         addressProvider.setAddress(marketCompressor, true);

//         address creditAccountCompressor = address(new CreditAccountCompressor(address(addressProvider)));
//         addressProvider.setAddress(creditAccountCompressor, true);

//         // NOTE: configurator must later accept ownership over new address provider
//         addressProvider.transferOwnership(Ownable(acl).owner());

//         string memory obj1 = "address_provider";
//         vm.serializeAddress(obj1, "addressProvider", address(addressProvider));

//         // "Mainnet", "Arbitrum", "Optimism", "Base"
//         string memory output = vm.serializeString(obj1, "network", "Mainnet");

//         string memory outDir = vm.envOr("OUT_DIR", string("."));
//         vm.writeJson(output, string(abi.encodePacked(outDir, "/address-provider.json")));
//     }

//     function _deployMarketConfigurator(address addressProviderLegacy, string memory name) internal {
//         address acl = IAddressProviderLegacy(addressProviderLegacy).getAddressOrRevert(AP_ACL, NO_VERSION_CONTROL);
//         address contractsRegister =
//             IAddressProviderLegacy(addressProviderLegacy).getAddressOrRevert(AP_CONTRACTS_REGISTER, NO_VERSION_CONTROL);
//         address treasury =
//             IAddressProviderLegacy(addressProviderLegacy).getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL);
//         address marketConfigurator = address(new MarketConfigurator(name, acl, contractsRegister, treasury));
//         console.log("new market configurator:", marketConfigurator);

//         string memory obj1 = "market_configurator";
//         vm.serializeAddress(obj1, "marketConfigurator", address(marketConfigurator));

//         // "Mainnet", "Arbitrum", "Optimism", "Base"
//         string memory output = vm.serializeString(obj1, "network", "Mainnet");

//         string memory outDir = vm.envOr("OUT_DIR", string("."));
//         vm.writeJson(output, string.concat(outDir, "/market-configurator-", name, ".json"));
//     }
// }
