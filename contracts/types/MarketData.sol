// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {ACLState} from "./ACLState.sol";
import {PoolState} from "./PoolState.sol";
import {PoolQuotaKeeperState} from "./PoolQuotaKeeperState.sol";
import {RateKeeperState} from "./RateKeeperState.sol";
import {PriceOracleState} from "./PriceOracleState.sol";
import {CreditManagerState} from "./CreditManagerState.sol";
import {CreditFacadeState} from "./CreditFacadeState.sol";
import {InterestRateModelState} from "./InterestRateModelState.sol";

struct MarketData {
    address riskCuratorManager;
    ACLState acl;
    PoolState pool;
    PoolQuotaKeeperState poolQuotaKeeper;
    InterestRateModelState interestRateModel;
    RateKeeperState rateKeeper;
    address[] tokens; // <- V3: collateral tokens, V3.1. from local price oracle
    CreditManagerData[] creditManagers;
    PriceOracleState priceOracleData;
    address[] emergencyLiquidators;
}
// LossLiquidatorPolicy

struct TokenBalance {
    address token;
    uint256 balance;
    bool isForbidden;
    bool isEnabled;
}

struct CreditManagerData {
    CreditFacadeState creditFacade;
    CreditManagerState creditManager;
}
