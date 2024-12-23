// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

// TODO: might need separate filters for markets and credit suites

/// @notice Credit account filters
/// @param  owner If set, match credit accounts owned by given address
/// @param  includeZeroDebt If set, also match accounts with zero debt
/// @param  minHealthFactor If set, only return accounts with health factor above this value
/// @param  maxHealthFactor If set, only return accounts with health factor below this value
/// @param  reverting If set, only match accounts with reverting collateral calculation
struct CreditAccountFilter {
    address owner;
    bool includeZeroDebt;
    uint16 minHealthFactor;
    uint16 maxHealthFactor;
    bool reverting;
}

/// @notice Credit manager filters
/// @param  configurators If set, match credit managers by given market configurators
/// @param  pools If set, match credit managers connected to given pools
/// @param  underlying If set, match credit managers with given underlying
struct MarketFilter {
    address[] configurators;
    address[] pools;
    address underlying;
}
