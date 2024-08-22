// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";

import {PoolCompressorV3} from "./PoolCompressor.sol";
import {PriceFeedCompressor} from "./PriceFeedCompressor.sol";

// // EXCEPTIONS
// import "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";

import {MarketData} from "../types/MarketData.sol";
import {PoolState} from "../types/PoolState.sol";

import "forge-std/console.sol";

// struct PriceOnDemand {
//     address priceFeed;
//     bytes callData;
// }

/// @title Data compressor 3.0.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
contract MarketCompressorV3 {
    // Contract version
    uint256 public constant version = 3_10;

    PriceFeedCompressor priceOracleCompressor;
    PoolCompressorV3 poolCompressor;

    error CreditManagerIsNotV3Exception();

    constructor(address priceOracleCompressorAddress) {
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
}
