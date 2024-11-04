// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import {
    AP_ACL,
    AP_CONTRACTS_REGISTER,
    AP_PRICE_ORACLE,
    AP_GEAR_STAKING,
    AP_DEGEN_NFT,
    AP_CONTRACTS_REGISTER
} from "@gearbox-protocol/governance/contracts/libraries/ContractLiterals.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {BitMask} from "@gearbox-protocol/core-v3/contracts/libraries/BitMask.sol";

import {PoolV3} from "@gearbox-protocol/core-v3/contracts/pool/PoolV3.sol";
import {GearStakingV3} from "@gearbox-protocol/core-v3/contracts/core/GearStakingV3.sol";
import {PriceOracleV3} from "@gearbox-protocol/core-v3/contracts/core/PriceOracleV3.sol";
import {PoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/pool/PoolQuotaKeeperV3.sol";
import {GaugeV3} from "@gearbox-protocol/core-v3/contracts/pool/GaugeV3.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";

import {IACL} from "@gearbox-protocol/governance/contracts/interfaces/IACL.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {CreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/credit/CreditFacadeV3.sol";
import {CreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/credit/CreditConfiguratorV3.sol";

import {PriceFeedMigrator} from "./migrators/PriceFeedMigrator.sol";

interface IAddressProviderV3Legacy {
    function getAddressOrRevert(bytes32 key, uint256 _version) external view returns (address result);
}

interface IOldContractsRegister {
    function getPools() external view returns (address[] memory pools);
}

interface IOldCreditConfigurator {
    function emergencyLiquidators() external view returns (address[] memory emergencyLiquidators);
}

contract MigratePools is Script {
    using LibString for bytes32;
    using BitMask for uint256;

    uint256 deployerPrivateKey;

    address acl;
    address oldPriceOracle;
    address oldGearStaking;
    address oldContractsRegister;

    mapping(address => address) poolToPriceOracle;

    PriceFeedMigrator pfMigrator;

    function run() external {
        deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address oldAddressProvider = vm.envAddress("OLD_ADDRESS_PROVIDER");

        pfMigrator = new PriceFeedMigrator(deployerPrivateKey);

        oldPriceOracle = IAddressProviderV3Legacy(oldAddressProvider).getAddressOrRevert(AP_PRICE_ORACLE, 300);
        oldGearStaking = IAddressProviderV3Legacy(oldAddressProvider).getAddressOrRevert(AP_GEAR_STAKING, 300);
        oldContractsRegister = IAddressProviderV3Legacy(oldAddressProvider).getAddressOrRevert(AP_CONTRACTS_REGISTER, 0);
        acl = IAddressProviderV3Legacy(oldAddressProvider).getAddressOrRevert(AP_ACL, 0);

        address[] memory pools = IOldContractsRegister(oldContractsRegister).getPools();

        for (uint256 i = 0; i < pools.length; ++i) {
            address pool = pools[i];

            if (PoolV3(pool).paused()) continue;

            vm.broadcast(deployerPrivateKey);
            poolToPriceOracle[pool] = address(new PriceOracleV3(acl));

            address[] memory quotedTokens =
                IPoolQuotaKeeperV3(IPoolQuotaKeeperV3(IPoolV3(pool).poolQuotaKeeper())).quotedTokens();

            for (uint256 j = 0; j < quotedTokens.length; ++j) {
                address token = quotedTokens[j];

                (address priceFeed, uint32 stalenessPeriod) = pfMigrator.migratePriceFeed(oldPriceOracle, token, false);

                vm.broadcast(deployerPrivateKey);
                PriceOracleV3(poolToPriceOracle[pool]).setPriceFeed(token, priceFeed, stalenessPeriod);

                (priceFeed, stalenessPeriod) = pfMigrator.migratePriceFeed(oldPriceOracle, token, true);

                if (priceFeed != address(0)) {
                    vm.broadcast(deployerPrivateKey);
                    PriceOracleV3(poolToPriceOracle[pool]).setReservePriceFeed(token, priceFeed, stalenessPeriod);
                }

                address[] memory updatableFeeds = pfMigrator.getUpdatablePriceFeeds(token);

                for (uint256 k = 0; k < updatableFeeds.length; ++k) {
                    vm.broadcast(deployerPrivateKey);
                    PriceOracleV3(poolToPriceOracle[pool]).addUpdatablePriceFeed(updatableFeeds[i]);
                }
            }

            address[] memory creditManagers = IPoolV3(pool).creditManagers();

            for (uint256 j = 0; j < creditManagers.length; ++j) {
                address creditManager = creditManagers[i];

                vm.broadcast(deployerPrivateKey);
                address creditConfigurator = address(new CreditConfiguratorV3(creditManagers[i]));

                address oldCreditFacade = ICreditManagerV3(creditManager).creditFacade();
                address creditFacade;

                {
                    address weth = CreditFacadeV3(oldCreditFacade).weth();
                    address degenNFT = CreditFacadeV3(oldCreditFacade).degenNFT();
                    bool expirable = CreditFacadeV3(oldCreditFacade).expirable();

                    /// TODO: ADD BOT LIST
                    creditFacade = address(new CreditFacadeV3(creditManager, address(0), weth, degenNFT, expirable));
                }

                address oldCreditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();

                vm.broadcast(deployerPrivateKey);
                CreditConfiguratorV3(creditConfigurator).upgradeCreditConfigurator(creditConfigurator);

                vm.broadcast(deployerPrivateKey);
                CreditConfiguratorV3(creditConfigurator).setCreditFacade(creditFacade, false);

                uint8 maxDebtPerBlockMultiplier = CreditFacadeV3(oldCreditFacade).maxDebtPerBlockMultiplier();

                vm.broadcast(deployerPrivateKey);
                CreditConfiguratorV3(creditConfigurator).setMaxDebtPerBlockMultiplier(maxDebtPerBlockMultiplier);

                if (CreditFacadeV3(oldCreditFacade).expirable() && CreditFacadeV3(creditFacade).expirable()) {
                    uint40 expirationDate = CreditFacadeV3(oldCreditFacade).expirationDate();

                    vm.broadcast(deployerPrivateKey);
                    CreditConfiguratorV3(creditConfigurator).setExpirationDate(expirationDate);
                }

                _migrateEmergencyLiquidators(oldCreditConfigurator, creditConfigurator);
                _migrateForbiddenTokens(
                    creditManager, creditConfigurator, CreditFacadeV3(oldCreditFacade).forbiddenTokenMask()
                );

                (uint128 minDebt, uint128 maxDebt) = CreditFacadeV3(oldCreditFacade).debtLimits();
                vm.broadcast(deployerPrivateKey);
                CreditConfiguratorV3(creditConfigurator).setDebtLimits(minDebt, maxDebt);
            }
        }
    }

    function _migrateEmergencyLiquidators(address oldCreditConfigurator, address newCreditConfigurator) internal {
        address[] memory emergencyLiquidators = IOldCreditConfigurator(oldCreditConfigurator).emergencyLiquidators();

        for (uint256 k = 0; k < emergencyLiquidators.length; ++k) {
            vm.broadcast(deployerPrivateKey);
            CreditConfiguratorV3(newCreditConfigurator).addEmergencyLiquidator(emergencyLiquidators[k]);
        }
    }

    function _migrateForbiddenTokens(address creditManager, address creditConfigurator, uint256 forbiddenTokensMask)
        internal
    {
        unchecked {
            while (forbiddenTokensMask != 0) {
                uint256 mask = forbiddenTokensMask.lsbMask();
                address token = ICreditManagerV3(creditManager).getTokenByMask(mask);

                vm.broadcast(deployerPrivateKey);
                CreditConfiguratorV3(creditConfigurator).forbidToken(token);
                forbiddenTokensMask ^= mask;
            }
        }
    }
}
