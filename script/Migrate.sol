// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import {IAddressProviderV3} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProviderV3.sol";
import {AddressProviderV3_1} from "@gearbox-protocol/governance/contracts/global/AddressProviderV3.sol";

import {
    AP_WETH_TOKEN,
    AP_GEAR_STAKING,
    AP_ACCOUNT_FACTORY,
    AP_POOL,
    AP_POOL_QUOTA_KEEPER,
    AP_POOL_RATE_KEEPER,
    AP_PRICE_ORACLE,
    AP_CREDIT_MANAGER,
    AP_CREDIT_FACADE,
    AP_CREDIT_CONFIGURATOR,
    AP_MARKET_CONFIGURATOR_FACTORY,
    AP_INTEREST_MODEL_FACTORY,
    AP_ADAPTER_FACTORY,
    AP_GEAR_TOKEN,
    AP_BOT_LIST,
    AP_GEAR_STAKING,
    AP_DEGEN_NFT,
    AP_ACCOUNT_FACTORY,
    AP_ROUTER,
    AP_INFLATION_ATTACK_BLOCKER,
    AP_ZERO_PRICE_FEED,
    AP_DEGEN_DISTRIBUTOR,
    AP_MULTI_PAUSE,
    AP_ZAPPER_REGISTER,
    AP_BYTECODE_REPOSITORY,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/governance/contracts/libraries/ContractLiterals.sol";
import {IACL} from "@gearbox-protocol/governance/contracts/interfaces/IACL.sol";
import {MarketConfiguratorLegacy} from "@gearbox-protocol/governance/contracts/market/MarketConfiguratorLegacy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {BytecodeRepository} from "@gearbox-protocol/governance/contracts/global/BytecodeRepository.sol";
import {InterestModelFactory} from "@gearbox-protocol/governance/contracts/factories/InterestModelFactory.sol";
import {PoolFactoryV3} from "@gearbox-protocol/governance/contracts/factories/PoolFactoryV3.sol";
import {CreditFactoryV3} from "@gearbox-protocol/governance/contracts/factories/CreditFactoryV3.sol";
import {PriceOracleFactoryV3} from "@gearbox-protocol/governance/contracts/factories/PriceOracleFactoryV3.sol";
import {MarketConfiguratorFactoryV3} from
    "@gearbox-protocol/governance/contracts/factories/MarketConfiguratorFactoryV3.sol";
import {AdapterFactoryV3} from "@gearbox-protocol/governance/contracts/factories/AdapterFactoryV3.sol";

import "forge-std/console.sol";

struct APMigration {
    string name;
    uint256 version;
}

/// @title Address provider V3 interface
interface IAddressProviderV3Legacy {
    function getAddressOrRevert(bytes32 key, uint256 _version) external view returns (address result);
}

address constant emergencyLiquidator = 0x7BD9c8161836b1F402233E80F55E3CaE0Fde4d87;

contract Migrate is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address oldAddressProvider = vm.envAddress("ADDRESS_PROVIDER");
        address vetoAdmin = vm.envAddress("VETO_ADMIN");

        address acl = IAddressProviderV3Legacy(oldAddressProvider).getAddressOrRevert("ACL", NO_VERSION_CONTROL);

        vm.startBroadcast(deployerPrivateKey);
        AddressProviderV3_1 _addressProvider = new AddressProviderV3_1();
        console.log("new address provider:", address(_addressProvider));

        _addressProvider.transferOwnership(IACL(acl).owner());

        /// AddressProvider migration
        APMigration[16] memory migrations = [
            APMigration({name: AP_WETH_TOKEN, version: 0}),
            APMigration({name: AP_GEAR_TOKEN, version: 0}),
            APMigration({name: AP_BOT_LIST, version: 300}),
            APMigration({name: AP_GEAR_STAKING, version: 300}),
            APMigration({name: AP_DEGEN_NFT, version: 1}),
            APMigration({name: AP_ACCOUNT_FACTORY, version: 0}),
            APMigration({name: AP_INFLATION_ATTACK_BLOCKER, version: 300}),
            APMigration({name: AP_ROUTER, version: 302}),
            APMigration({name: AP_ZERO_PRICE_FEED, version: 0}),
            APMigration({name: AP_ZAPPER_REGISTER, version: 300}),
            APMigration({name: AP_MULTI_PAUSE, version: 0}),
            APMigration({name: AP_DEGEN_DISTRIBUTOR, version: 300}),
            APMigration({name: "PARTIAL_LIQUIDATION_BOT", version: 300}),
            APMigration({name: "DELEVERAGE_BOT_PEGGED", version: 300}),
            APMigration({name: "DELEVERAGE_BOT_LV", version: 300}),
            APMigration({name: "DELEVERAGE_BOT_HV", version: 300})
        ];

        uint256 len = migrations.length;

        for (uint256 i; i < len; i++) {
            try IAddressProviderV3Legacy(oldAddressProvider).getAddressOrRevert(
                stringToBytes32(migrations[i].name), migrations[i].version
            ) returns (address oldAddress) {
                _addressProvider.setAddress({
                    key: migrations[i].name,
                    value: oldAddress,
                    saveVersion: migrations[i].version != NO_VERSION_CONTROL
                });
            } catch {
                console.log("Failed to migrate", migrations[i].name);
            }
        }

        /// Deploy new factories
        address repository = address(new BytecodeRepository());
        _addressProvider.setAddress(AP_BYTECODE_REPOSITORY, repository, false);

        address factory = address(new InterestModelFactory());
        _addressProvider.setAddress(AP_INTEREST_MODEL_FACTORY, factory, true);

        factory = address(new PoolFactoryV3(address(_addressProvider)));
        _addressProvider.setAddress("POOL_FACTORY", factory, true);

        factory = address(new CreditFactoryV3(address(_addressProvider)));
        _addressProvider.setAddress("CREDIT_FACTORY", factory, true);

        factory = address(new PriceOracleFactoryV3(address(_addressProvider)));
        _addressProvider.setAddress("PRICE_ORACLE_FACTORY", factory, true);

        factory = address(new MarketConfiguratorFactoryV3(address(_addressProvider)));
        _addressProvider.setAddress("MARKET_CONFIGURATOR_FACTORY", factory, true);

        factory = address(new AdapterFactoryV3());
        _addressProvider.setAddress(AP_ADAPTER_FACTORY, factory, true);

        /// Deploy MarketConfiguratorLegacy
        bytes memory bytecode = type(MarketConfiguratorLegacy).creationCode;
        bytes memory parameters = abi.encode(oldAddressProvider, address(_addressProvider), "ChaosLabs", vetoAdmin);

        bytes memory bytecodeWithParams = abi.encodePacked(bytecode, parameters);
        address mcl = Create2.computeAddress(0, keccak256(bytecodeWithParams));

        /// set this contract to add mcl as marketConfigurator
        _addressProvider.setAddress(AP_MARKET_CONFIGURATOR_FACTORY, deployer, false);

        /// Register this marketConfigurator in AddressProvider
        _addressProvider.addMarketConfigurator(address(mcl));

        /// Deploy MarketConfiguratorLegacy
        Create2.deploy(0, 0, bytecodeWithParams);

        factory = address(new MarketConfiguratorFactoryV3(address(_addressProvider)));
        _addressProvider.setAddress(AP_MARKET_CONFIGURATOR_FACTORY, factory, false);

        address priceFeedCompressor = address(new PriceFeedCompressor());
        address marketCompressor = address(new MarketCompressor(addressProvider, priceFeedCompressor));

        vm.stopBroadcast();

        string memory path = "address.toml";
        string memory data = string.concat("ADDRESS_PROVIDER=", vm.toString(address(_addressProvider)), "\n");
        vm.writeFile(path, data);
    }

    function stringToBytes32(string memory source) public pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }

        assembly {
            result := mload(add(source, 32))
        }
    }
}
