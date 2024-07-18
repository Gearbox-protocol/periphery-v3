// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

struct PoolState {
    // contract properties
    address addr;
    uint256 version;
    bytes32 contractType;
    //
    // ERC20 Properties
    string symbol;
    string name;
    uint8 decimals;
    uint256 totalSupply;
    //
    // connected contracts
    address poolQuotaKeeper;
    address interestRateModel;
    address controller;
    //
    address underlying;
    uint256 availableLiquidity;
    uint256 expectedLiquidity;
    uint256 baseInterestIndex;
    uint256 baseInterestRate;
    uint256 dieselRate_RAY;
    uint256 totalBorrowed;
    uint256 totalAssets;
    uint256 supplyRate;
    uint256 withdrawFee;
    //
    // Limits
    uint256 totalDebtLimit;
    CreditManagerDebtParams[] creditManagerDebtParams;
    //
    // updates
    uint256 lastBaseInterestUpdate;
    uint256 baseInterestIndexLU;
    //
    // Paused
    bool isPaused;
}

struct CreditManagerDebtParams {
    address creditManager;
    uint256 borrowed;
    uint256 limit;
    uint256 availableToBorrow;
}
