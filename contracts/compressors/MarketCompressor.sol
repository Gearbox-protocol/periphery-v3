// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";

import {IACL} from "@gearbox-protocol/governance/contracts/interfaces/IACL.sol";
import {IContractsRegister} from "@gearbox-protocol/governance/contracts/interfaces/IContractsRegister.sol";
import {IAddressProvider} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProvider.sol";
import {IMarketConfigurator} from "@gearbox-protocol/governance/contracts/interfaces/IMarketConfigurator.sol";
import {IMarketConfiguratorFactory} from
    "@gearbox-protocol/governance/contracts/interfaces/IMarketConfiguratorFactory.sol";
import {
    AP_MARKET_CONFIGURATOR_FACTORY,
    NO_VERSION_CONTROL,
    ROLE_EMERGENCY_LIQUIDATOR,
    ROLE_PAUSABLE_ADMIN,
    ROLE_UNPAUSABLE_ADMIN
} from "@gearbox-protocol/governance/contracts/libraries/ContractLiterals.sol";

import {Contains} from "../libraries/Contains.sol";

import {MarketFilter} from "../types/Filters.sol";

import {CreditSuiteCompressor} from "./CreditSuiteCompressor.sol";
import {PoolCompressor} from "./PoolCompressor.sol";
import {PriceFeedCompressor} from "./PriceFeedCompressor.sol";
import {TokenCompressor} from "./TokenCompressor.sol";

import {BaseParams} from "../types/BaseState.sol";
import {CreditSuiteData} from "../types/CreditSuiteData.sol";
import {MarketData} from "../types/MarketData.sol";
import {TokenData} from "../types/TokenData.sol";
import {PoolState} from "../types/PoolState.sol";
import {PriceOracleState} from "../types/PriceOracleState.sol";

import {IMarketCompressor} from "../interfaces/IMarketCompressor.sol";
import {
    AP_MARKET_COMPRESSOR,
    AP_POOL_COMPRESSOR,
    AP_TOKEN_COMPRESSOR,
    AP_PRICE_FEED_COMPRESSOR,
    AP_CREDIT_SUITE_COMPRESSOR
} from "../libraries/Literals.sol";

/// @title Data compressor 3.0.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
contract MarketCompressor is IMarketCompressor {
    using Contains for address[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = AP_MARKET_COMPRESSOR;

    address public immutable addressProvider;
    address public immutable marketConfiguratorFactory;

    PoolCompressor poolCompressor;
    TokenCompressor tokenCompressor;
    PriceFeedCompressor priceOracleCompressor;
    CreditSuiteCompressor creditSuiteCompressor;

    struct Pool {
        address addr;
        address configurator;
    }

    constructor(address addressProvider_) {
        addressProvider = addressProvider_;

        // TODO: change to normal discovery

        marketConfiguratorFactory =
            IAddressProvider(addressProvider_).getAddressOrRevert(AP_MARKET_CONFIGURATOR_FACTORY, NO_VERSION_CONTROL);

        poolCompressor = PoolCompressor(IAddressProvider(addressProvider_).getAddressOrRevert(AP_POOL_COMPRESSOR, 3_10));
        tokenCompressor =
            TokenCompressor(IAddressProvider(addressProvider_).getAddressOrRevert(AP_TOKEN_COMPRESSOR, 3_10));
        creditSuiteCompressor = CreditSuiteCompressor(
            IAddressProvider(addressProvider_).getAddressOrRevert(AP_CREDIT_SUITE_COMPRESSOR, 3_10)
        );
        priceOracleCompressor =
            PriceFeedCompressor(IAddressProvider(addressProvider_).getAddressOrRevert(AP_PRICE_FEED_COMPRESSOR, 3_10));
    }

    function getMarkets(MarketFilter memory filter) external view returns (MarketData[] memory result) {
        Pool[] memory pools = _getPools(filter);
        result = new MarketData[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            result[i] = getMarketData(pools[i].addr, pools[i].configurator);
        }
    }

    function getUpdatablePriceFeeds(MarketFilter memory filter)
        external
        view
        returns (BaseParams[] memory updatablePriceFeeds)
    {
        Pool[] memory pools = _getPools(filter);
        uint256 numPools = pools.length;
        PriceOracleState[] memory poStates = new PriceOracleState[](numPools);
        uint256 numUpdatable;
        for (uint256 i; i < numPools; ++i) {
            address[] memory tokens = _getTokens(pools[i].addr);
            address priceOracle = _getPriceOracle(pools[i].addr, pools[i].configurator);
            poStates[i] = priceOracleCompressor.getPriceOracleState(priceOracle, tokens);
            for (uint256 j; j < poStates[i].priceFeedStructure.length; ++j) {
                if (poStates[i].priceFeedStructure[j].updatable) ++numUpdatable;
            }
        }

        updatablePriceFeeds = new BaseParams[](numUpdatable);
        uint256 k;
        for (uint256 i; i < numPools; ++i) {
            for (uint256 j; j < poStates[i].priceFeedStructure.length; ++j) {
                if (poStates[i].priceFeedStructure[j].updatable) {
                    updatablePriceFeeds[k++] = poStates[i].priceFeedStructure[j].baseParams;
                }
            }
        }
    }

    function getMarketData(address pool) external view returns (MarketData memory result) {
        // After full migration to v3.1.x governance system, pool's market configurator will be the owner of its ACL.
        // Before that, however, there's no way to recover it unless it is provided directly or with market filter.
        return getMarketData(pool, Ownable(IPoolV3(pool).acl()).owner());
    }

    function getMarketData(address pool, address configurator) public view returns (MarketData memory result) {
        result.acl = IMarketConfigurator(configurator).acl();
        result.contractsRegister = IMarketConfigurator(configurator).contractsRegister();
        result.treasury = IMarketConfigurator(configurator).treasury();

        result.pool = poolCompressor.getPoolState(pool);
        result.poolQuotaKeeper = poolCompressor.getPoolQuotaKeeperState(result.pool.poolQuotaKeeper);
        result.rateKeeper = poolCompressor.getRateKeeperState(result.poolQuotaKeeper.rateKeeper);
        result.interestRateModel = poolCompressor.getInterestRateModelState(result.pool.interestRateModel);

        address[] memory tokens = _getTokens(pool);
        result.tokens = new TokenData[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            result.tokens[i] = tokenCompressor.getTokenInfo(tokens[i]);
        }

        address[] memory creditManagers = IContractsRegister(result.contractsRegister).getCreditManagers(pool);
        uint256 numCreditManagers = creditManagers.length;
        result.creditManagers = new CreditSuiteData[](numCreditManagers);
        for (uint256 i; i < numCreditManagers; ++i) {
            result.creditManagers[i] = creditSuiteCompressor.getCreditSuiteData(creditManagers[i]);
        }

        result.priceOracleData = priceOracleCompressor.getPriceOracleState(_getPriceOracle(pool, configurator), tokens);
        result.lossPolicy = poolCompressor.getLossPolicyState(_getLossPolicy(pool, configurator));

        result.configurator = configurator;
        result.pausableAdmins = IACL(result.acl).getRoleHolders(ROLE_PAUSABLE_ADMIN);
        result.unpausableAdmins = IACL(result.acl).getRoleHolders(ROLE_UNPAUSABLE_ADMIN);
        result.emergencyLiquidators = IACL(result.acl).getRoleHolders(ROLE_EMERGENCY_LIQUIDATOR);

        // TODO: add zappers
    }

    function _getTokens(address pool) internal view returns (address[] memory tokens) {
        address quotaKeeper = IPoolV3(pool).poolQuotaKeeper();
        address[] memory quotedTokens = IPoolQuotaKeeperV3(quotaKeeper).quotedTokens();
        uint256 numTokens = quotedTokens.length;
        tokens = new address[](numTokens + 1);
        tokens[0] = IPoolV3(pool).asset();
        for (uint256 i; i < numTokens; ++i) {
            tokens[i + 1] = quotedTokens[i];
        }
    }

    function _getPriceOracle(address pool, address configurator) internal view returns (address) {
        address contractsRegister = IMarketConfigurator(configurator).contractsRegister();
        return IContractsRegister(contractsRegister).getPriceOracle(pool);
    }

    function _getLossPolicy(address pool, address configurator) internal view returns (address) {
        address contractsRegister = IMarketConfigurator(configurator).contractsRegister();
        return IContractsRegister(contractsRegister).getLossPolicy(pool);
    }

    /// @dev Pools discovery
    function _getPools(MarketFilter memory filter) internal view returns (Pool[] memory pools) {
        address[] memory configurators = filter.configurators.length != 0
            ? filter.configurators
            : IMarketConfiguratorFactory(marketConfiguratorFactory).getMarketConfigurators();

        // rough estimate of maximum number of credit pools
        uint256 max;
        for (uint256 i; i < configurators.length; ++i) {
            address contractsRegister = IMarketConfigurator(configurators[i]).contractsRegister();
            max += IContractsRegister(contractsRegister).getPools().length;
        }

        // allocate the array with maximum potentially needed size (total number of credit pools can be assumed
        // to be relatively small and the function is only called once, so memory expansion cost is not an issue)
        pools = new Pool[](max);
        uint256 num;

        for (uint256 i; i < configurators.length; ++i) {
            address contractsRegister = IMarketConfigurator(configurators[i]).contractsRegister();
            address[] memory poolsMC = IContractsRegister(contractsRegister).getPools();
            for (uint256 j; j < poolsMC.length; ++j) {
                address pool = poolsMC[j];
                // FIXME: that's kinda weird to filter pools by pools
                if (filter.pools.length != 0 && !filter.pools.contains(pool)) continue;
                if (filter.underlying != address(0) && IPoolV3(pool).asset() != filter.underlying) continue;
                pools[num++] = Pool({addr: pool, configurator: configurators[i]});
            }
        }

        // trim the array to its actual size
        assembly {
            mstore(pools, num)
        }
    }
}
