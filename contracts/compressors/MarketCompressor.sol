// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IContractsRegister} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IContractsRegister.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {IAddressProvider} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProvider.sol";
import {IMarketConfigurator} from "@gearbox-protocol/governance/contracts/interfaces/IMarketConfigurator.sol";
import {IMarketConfiguratorFactory} from
    "@gearbox-protocol/governance/contracts/interfaces/IMarketConfiguratorFactory.sol";
import {
    AP_MARKET_CONFIGURATOR_FACTORY,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/governance/contracts/libraries/ContractLiterals.sol";

import {Contains} from "../libraries/Contains.sol";

import {MarketFilter} from "../types/CreditAccountState.sol";

import {PoolCompressorV3} from "./PoolCompressor.sol";
import {PriceFeedCompressor} from "./PriceFeedCompressor.sol";
import {TokenCompressor} from "./TokenCompressor.sol";

import {BaseParams} from "../types/BaseState.sol";
import {MarketData, CreditManagerData} from "../types/MarketData.sol";
import {TokenData} from "../types/TokenData.sol";
import {PoolState} from "../types/PoolState.sol";
import {PriceOracleState} from "../types/PriceOracleState.sol";

import {IMarketCompressor} from "../interfaces/IMarketCompressor.sol";

/// @title Data compressor 3.0.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
contract MarketCompressor is IMarketCompressor {
    using Contains for address[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "MARKET_COMPRESSOR";

    /// @notice Address provider contract address
    address public immutable addressProvider;

    address public immutable marketConfiguratorFactory;

    TokenCompressor tokenCompressor;
    PriceFeedCompressor priceOracleCompressor;
    PoolCompressorV3 poolCompressor;

    error CreditManagerIsNotV3Exception();

    constructor(address addressProvider_, address priceOracleCompressorAddress) {
        addressProvider = addressProvider_;
        marketConfiguratorFactory =
            IAddressProvider(addressProvider_).getAddressOrRevert(AP_MARKET_CONFIGURATOR_FACTORY, NO_VERSION_CONTROL);

        tokenCompressor = new TokenCompressor();
        poolCompressor = new PoolCompressorV3();
        priceOracleCompressor = PriceFeedCompressor(priceOracleCompressorAddress);
    }

    function getMarkets(MarketFilter memory filter) external view returns (MarketData[] memory result) {
        address[] memory pools = _getPools(filter);
        result = new MarketData[](pools.length);

        for (uint256 i = 0; i < pools.length; i++) {
            result[i] = getMarketData(pools[i]);
        }
    }

    function getUpdatablePriceFeeds(MarketFilter memory filter)
        external
        view
        returns (BaseParams[] memory updatablePriceFeeds)
    {
        address[] memory pools = _getPools(filter);
        uint256 numPools = pools.length;
        PriceOracleState[] memory poStates = new PriceOracleState[](numPools);
        uint256 numUpdatable;
        for (uint256 i; i < numPools; ++i) {
            address[] memory tokens = _getTokens(pools[i]);
            address priceOracle = _getPriceOracle(poolCompressor.getPoolState(pools[i]));
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

    function getMarketData(address pool) public view returns (MarketData memory result) {
        result.acl = IPoolV3(pool).acl();
        result.pool = poolCompressor.getPoolState(pool);
        result.poolQuotaKeeper = poolCompressor.getPoolQuotaKeeperState(result.pool.poolQuotaKeeper);
        result.rateKeeper = poolCompressor.getRateKeeperState(result.poolQuotaKeeper.rateKeeper);
        result.interestRateModel = poolCompressor.getInterestRateModelState(result.pool.interestRateModel);

        address[] memory tokens = _getTokens(pool);
        result.tokens = new TokenData[](tokens.length);
        for (uint256 i; i < tokens.length; i++) {
            result.tokens[i] = tokenCompressor.getTokenInfo(tokens[i]);
        }

        // creditManager
        uint256 len = result.pool.creditManagerDebtParams.length;
        result.creditManagers = new CreditManagerData[](len);
        for (uint256 i = 0; i < len; i++) {
            result.creditManagers[i] =
                poolCompressor.getCreditManagerData(result.pool.creditManagerDebtParams[i].creditManager);
        }

        address priceOracle = _getPriceOracle(result.pool);
        result.priceOracleData = priceOracleCompressor.getPriceOracleState(priceOracle, tokens);
    }

    function _getTokens(address pool) internal view returns (address[] memory tokens) {
        // under proper configuration, equivalent to price oracle's `getTokens`
        address quotaKeeper = IPoolV3(pool).poolQuotaKeeper();
        address[] memory quotedTokens = IPoolQuotaKeeperV3(quotaKeeper).quotedTokens();
        uint256 numTokens = quotedTokens.length;
        tokens = new address[](numTokens + 1);
        tokens[0] = IPoolV3(pool).asset();
        for (uint256 i; i < numTokens; ++i) {
            tokens[i + 1] = quotedTokens[i];
        }
    }

    function _getPriceOracle(PoolState memory ps) internal view returns (address) {
        // TODO: read from market configurator instead once structure is known
        if (ps.creditManagerDebtParams.length == 0) {
            return address(0);
        }

        return ICreditManagerV3(ps.creditManagerDebtParams[0].creditManager).priceOracle();
    }

    /// @dev Pools discovery
    function _getPools(MarketFilter memory filter) internal view returns (address[] memory pools) {
        address[] memory configurators = IMarketConfiguratorFactory(marketConfiguratorFactory).getMarketConfigurators();

        // rough estimate of maximum number of credit pools
        uint256 max;
        for (uint256 i; i < configurators.length; ++i) {
            address contractsRegister = IMarketConfigurator(configurators[i]).contractsRegister();
            max += IContractsRegister(contractsRegister).getPools().length;
        }

        // allocate the array with maximum potentially needed size (total number of credit pools can be assumed
        // to be relatively small and the function is only called once, so memory expansion cost is not an issue)
        pools = new address[](max);
        uint256 num;

        for (uint256 i; i < configurators.length; ++i) {
            if (filter.curators.length != 0) {
                if (!filter.curators.contains(Ownable(configurators[i]).owner())) continue;
            }

            address contractsRegister = IMarketConfigurator(configurators[i]).contractsRegister();
            address[] memory poolsMC = IContractsRegister(contractsRegister).getPools();
            for (uint256 j; j < poolsMC.length; ++j) {
                address currentPool = poolsMC[j];
                if (filter.pools.length != 0) {
                    if (!filter.pools.contains(currentPool)) continue;
                }

                if (filter.underlying != address(0)) {
                    if (IPoolV3(currentPool).asset() != filter.underlying) {
                        continue;
                    }
                }

                pools[num++] = currentPool;
            }
        }

        // trim the array to its actual size
        assembly {
            mstore(pools, num)
        }
    }
}
