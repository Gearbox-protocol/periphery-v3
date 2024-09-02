// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import {IAddressProviderV3_1} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProviderV3_1.sol";
import {AddressProviderV3_1} from "@gearbox-protocol/governance/contracts/global/AddressProviderV3.sol";

import {PriceFeedCompressor} from "../contracts/compressors/PriceFeedCompressor.sol";
import {MarketCompressor} from "../contracts/compressors/MarketCompressor.sol";
import {LibString} from "@solady/utils/LibString.sol";

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

import {Migrate} from "@gearbox-protocol/governance/script/Migrate.sol";

import "forge-std/console.sol";

struct APMigration {
    bytes32 name;
    uint256 version;
}

/// @title Address provider V3 interface
interface IAddressProviderV3Legacy {
    function getAddressOrRevert(bytes32 key, uint256 _version) external view returns (address result);
}

address constant emergencyLiquidator = 0x7BD9c8161836b1F402233E80F55E3CaE0Fde4d87;

contract Migrate2 is Migrate {
    using LibString for bytes32;

    function run() external override(Migrate) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address oldAddressProvider = vm.envAddress("ADDRESS_PROVIDER");
        address vetoAdmin = vm.envAddress("VETO_ADMIN");
        console.log(vetoAdmin);

        address acl = IAddressProviderV3Legacy(oldAddressProvider).getAddressOrRevert("ACL", NO_VERSION_CONTROL);

        vm.startBroadcast(deployerPrivateKey);

        AddressProviderV3_1 _addressProvider =
            AddressProviderV3_1(_deployGovernance3_1(oldAddressProvider, vetoAdmin, deployer));

        address priceFeedCompressor = address(new PriceFeedCompressor());
        _addressProvider.setAddress(priceFeedCompressor, true);

        address newContract = address(new MarketCompressor(address(_addressProvider), priceFeedCompressor));
        _addressProvider.setAddress(newContract, true);

        vm.stopBroadcast();

        string memory obj1 = "address_provider";

        vm.serializeAddress(obj1, "addressProvider", address(_addressProvider));

        // "Mainnet", "Arbitrum", "Optimism", "Base"
        string memory output = vm.serializeString(obj1, "network", "Mainnet");

        vm.writeJson(output, "address-provider.json");
    }
}
