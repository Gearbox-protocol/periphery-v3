// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

struct CreditManagerState {
    address addr;
    uint256 version;
    bytes32 contractType;
    string name;
    address creditFacade;
    uint256 cfVersion;
    bytes32 cfContractType;
    address creditConfigurator;
    address underlying;
    address pool;
    uint256 totalDebt;
    uint256 totalDebtLimit;
    uint256 minDebt;
    uint256 maxDebt;
    address degenNFT;
    uint256 availableToBorrow;
    address[] collateralTokens;
    ContractAdapter[] adapters;
    uint256[] liquidationThresholds;
    uint256 forbiddenTokenMask; // V2 only: mask which forbids some particular tokens
    uint8 maxEnabledTokensLength; // V2 only: in V1 as many tokens as the CM can support (256)
    uint16 feeInterest; // Interest fee protocol charges: fee = interest accrues * feeInterest
    uint16 feeLiquidation; // Liquidation fee protocol charges: fee = totalValue * feeLiquidation
    uint16 liquidationDiscount; // Miltiplier to get amount which liquidator should pay: amount = totalValue * liquidationDiscount
    uint16 feeLiquidationExpired; // Liquidation fee protocol charges on expired accounts
    uint16 liquidationDiscountExpired; // Multiplier for the amount the liquidator has to pay when closing an expired account
}

struct ContractAdapter {
    address targetContract;
    address adapter;
    uint8 adapterType;
    uint256 version;
    bytes stateSerialised;
}
