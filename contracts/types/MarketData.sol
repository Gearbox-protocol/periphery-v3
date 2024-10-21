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
import {BaseState, BaseParams} from "./BaseState.sol";
import {TokenData} from "./TokenData.sol";

struct MarketData {
    // MarketConfigurator baseParams
    BaseParams baseParams;
    // Owner who manages market
    address owner;
    address acl;
    // Syntax sugar ?
    // address underlying;
    // Risk curator name
    string name;
    PoolState pool;
    PoolQuotaKeeperState poolQuotaKeeper;
    BaseState interestRateModel;
    RateKeeperState rateKeeper;
    PriceOracleState priceOracleData;
    TokenData[] tokens; // <- V3: collateral tokens, V3.1. from local price oracle
    CreditManagerData[] creditManagers;
    // ZappersInfo
    ZapperInfo[] zappers;
    // Roles
    address[] pausableAdmins;
    address[] unpausableAdmins;
    address[] emergencyLiquidators;
}
// LossLiquidatorPolicy
// ControllerTimelock (?)

struct ZapperInfo {
    BaseParams baseParams;
    address tokenIn;
    address tokenOut;
}

struct ContractAdapter {
    BaseParams baseParams;
    address targetContract;
}

struct CreditManagerData {
    CreditFacadeState creditFacade;
    CreditManagerState creditManager;
    BaseState creditConfigurator;
    ContractAdapter[] adapters;
    uint256 totalDebt;
    uint256 totalDebtLimit;
    uint256 availableToBorrow;
}
