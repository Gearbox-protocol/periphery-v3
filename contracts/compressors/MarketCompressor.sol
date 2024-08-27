// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IContractsRegister} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IContractsRegister.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {Contains} from "../libraries/Contains.sol";

import {IAddressProviderV3} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProviderV3.sol";
import {IMarketConfiguratorV3} from "@gearbox-protocol/governance/contracts/interfaces/IMarketConfiguratorV3.sol";

import {PoolCompressorV3} from "./PoolCompressor.sol";
import {PriceFeedCompressor} from "./PriceFeedCompressor.sol";

// // EXCEPTIONS
// import "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";

import {MarketData} from "../types/MarketData.sol";
import {PoolState} from "../types/PoolState.sol";

import {IMarketCompressor} from "../interfaces/IMarketCompressor.sol";

import "forge-std/console.sol";

/// @title Data compressor 3.0.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
contract MarketCompressor is IMarketCompressor {
    using Contains for address[];
    // Contract version

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "MARKET_COMPRESSOR";

    /// @notice Address provider contract address
    address public immutable ADDRESS_PROVIDER;

    PriceFeedCompressor priceOracleCompressor;
    PoolCompressorV3 poolCompressor;

    error CreditManagerIsNotV3Exception();

    constructor(address addressProvider, address priceOracleCompressorAddress) {
        ADDRESS_PROVIDER = addressProvider;
        addressProvider = addressProvider;
        poolCompressor = new PoolCompressorV3();
        priceOracleCompressor = PriceFeedCompressor(priceOracleCompressorAddress);
    }

    function getMarketData(address pool) public view returns (MarketData memory result) {
        result.pool = poolCompressor.getPoolState(pool);
        result.poolQuotaKeeper = poolCompressor.getPoolQuotaKeeperState(result.pool.poolQuotaKeeper);
        result.rateKeeper = poolCompressor.getRateKeeperState(result.poolQuotaKeeper.rateKeeper);
        result.interestRateModel = poolCompressor.getInterestRateModelState(result.pool.interestRateModel);

        address priceOracle = _getPriceOracle(result.pool);
        address[] memory tokens = IPoolQuotaKeeperV3(result.pool.poolQuotaKeeper).quotedTokens();

        result.tokens = new address[](tokens.length + 1);
        result.tokens[0] = result.pool.underlying;

        for (uint256 i = 0; i < tokens.length; i++) {
            result.tokens[i + 1] = tokens[i];
        }
        // How to query if no credit mangers are deployed?
        result.priceOracleData = priceOracleCompressor.getPriceOracleState(priceOracle, result.tokens);
    }

    function _getPriceOracle(PoolState memory ps) internal view returns (address) {
        if (ps.creditManagerDebtParams.length == 0) {
            return address(0);
        }

        return ICreditManagerV3(ps.creditManagerDebtParams[0].creditManager).priceOracle();
    }

    /// @dev Credit managers discovery
    function _getPools(address[] memory riskCurators) internal view returns (address[] memory pools) {
        address[] memory configurators = IAddressProviderV3(ADDRESS_PROVIDER).marketConfigurators();

        // rough estimate of maximum number of credit managers
        uint256 max;
        for (uint256 i; i < configurators.length; ++i) {
            if (riskCurators.contains(IMarketConfiguratorV3(configurators[i]).owner())) {
                address cr = IMarketConfiguratorV3(configurators[i]).contractsRegister();
                max += IContractsRegister(cr).getCreditManagers().length;
            }
        }

        // allocate the array with maximum potentially needed size (total number of credit managers can be assumed
        // to be relatively small and the function is only called once, so memory expansion cost is not an issue)
        pools = new address[](max);
        uint256 num;

        for (uint256 i; i < configurators.length; ++i) {
            if (riskCurators.contains(IMarketConfiguratorV3(configurators[i]).owner())) {
                address cr = IMarketConfiguratorV3(configurators[i]).contractsRegister();
                address[] memory managers = IContractsRegister(cr).getPools();
                for (uint256 j; j < managers.length; ++j) {
                    // we're only concerned with v3 contracts
                    uint256 ver = IVersion(managers[j]).version();
                    if (ver < 3_00 || ver > 3_99) continue;

                    pools[num++] = managers[j];
                }
            }
        }
    }
}
