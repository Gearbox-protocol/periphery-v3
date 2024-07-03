// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

struct PoolQuotaKeeperState {
    address addr;
    uint256 version;
    address rateKeeper;
    QuotaTokenParams[] quotas;
    address[] creditManagers;
    uint40 lastQuotaRateUpdate;
}

struct QuotaTokenParams {
    address token;
    uint16 rate;
    uint192 cumulativeIndexLU;
    uint16 quotaIncreaseFee;
    uint96 totalQuoted;
    uint96 limit;
    bool isActive;
}
