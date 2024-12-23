// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {BaseParams} from "./BaseState.sol";

struct PoolState {
    BaseParams baseParams;
    //
    // ERC20 Properties
    string symbol; // +
    string name; // +
    uint8 decimals; // +
    uint256 totalSupply; // +
    //
    // connected contracts
    address poolQuotaKeeper; // +
    address interestRateModel; // +
    address treasury; // +
    address underlying; // +
    uint256 availableLiquidity; // +
    uint256 expectedLiquidity; // +
    uint256 baseInterestIndex; // +
    uint256 baseInterestRate; // +
    uint256 dieselRate;
    uint256 totalBorrowed; // +
    uint256 totalAssets; // +
    uint256 supplyRate; // +
    uint256 withdrawFee; // +
    // Limits
    uint256 totalDebtLimit; // +
    CreditManagerDebtParams[] creditManagerDebtParams; // +
    //
    // updates
    uint256 baseInterestIndexLU; // +
    uint256 expectedLiquidityLU; // +
    uint256 quotaRevenue; // +
    uint40 lastBaseInterestUpdate;
    uint40 lastQuotaRevenueUpdate;
    //
    // Paused
    bool isPaused;
}

struct CreditManagerDebtParams {
    address creditManager;
    uint256 borrowed;
    uint256 limit;
}
