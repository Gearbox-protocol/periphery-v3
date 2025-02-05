// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {PoolState} from "./PoolState.sol";
import {PoolQuotaKeeperState} from "./PoolQuotaKeeperState.sol";
import {RateKeeperState} from "./RateKeeperState.sol";
import {PriceOracleState} from "./PriceOracleState.sol";
import {CreditManagerState} from "./CreditManagerState.sol";
import {CreditFacadeState} from "./CreditFacadeState.sol";
import {CreditSuiteData} from "./CreditSuiteData.sol";
import {BaseState, BaseParams} from "./BaseState.sol";
import {TokenData} from "./TokenData.sol";

struct MarketData {
    address acl;
    address contractsRegister;
    address treasury;
    PoolState pool;
    PoolQuotaKeeperState poolQuotaKeeper;
    BaseState interestRateModel;
    RateKeeperState rateKeeper;
    PriceOracleState priceOracleData;
    BaseState lossPolicy;
    TokenData[] tokens;
    CreditSuiteData[] creditManagers;
    address configurator;
    address[] pausableAdmins;
    address[] unpausableAdmins;
    address[] emergencyLiquidators;
}
