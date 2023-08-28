// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.17;

import {ScheduledWithdrawal} from "@gearbox-protocol/core-v3/contracts/interfaces/IWithdrawalManagerV3.sol";

struct TokenBalance {
    address token;
    uint256 balance;
    bool isForbidden;
    bool isEnabled;
    bool isQuoted;
    uint256 quota;
    uint16 quotaRate;
}

struct QuotaInfo {
    address token;
    uint16 rate;
    uint16 quotaIncreaseFee;
    uint96 totalQuoted;
    uint96 limit;
}

struct ContractAdapter {
    address targetContract;
    address adapter;
}

struct CreditAccountData {
    // if not successful, priceFeedsNeeded are filled with the data
    bool isSuccessful;
    address[] priceFeedsNeeded;
    address addr;
    address borrower;
    address creditManager;
    address creditFacade;
    address underlying;
    uint256 debt;
    uint256 cumulativeIndexNow;
    uint256 cumulativeIndexLastUpdate;
    uint128 cumulativeQuotaInterest;
    uint256 accruedInterest;
    uint256 accruedFees;
    uint256 totalDebtUSD;
    uint256 totalValue;
    uint256 totalValueUSD;
    uint256 twvUSD;
    uint256 enabledTokensMask;
    ///
    uint256 healthFactor;
    uint256 baseBorrowRate;
    uint256 aggregatedBorrowRate;
    TokenBalance[] balances;
    uint64 since;
    uint256 cfVersion;
    // V3 features
    uint40 expirationDate;
    address[] activeBots;
    uint256 maxApprovedBots;
    ScheduledWithdrawal[2] schedultedWithdrawals;
}

struct CreditManagerData {
    address addr;
    address underlying;
    address pool;
    uint256 totalDebt;
    uint256 totalDebtLimit;
    uint256 baseBorrowRate;
    uint256 minDebt;
    uint256 maxDebt;
    uint256 availableToBorrow;
    address[] collateralTokens;
    ContractAdapter[] adapters;
    uint256[] liquidationThresholds;
    uint256 version;
    address creditFacade; // V2 only: address of creditFacade
    address creditConfigurator; // V2 only: address of creditConfigurator
    bool isDegenMode; // V2 only: true if contract is in Degen mode
    address degenNFT; // V2 only: degenNFT, address(0) if not in degen mode
    bool isIncreaseDebtForbidden; // V2 only: true if increasing debt is forbidden
    uint256 forbiddenTokenMask; // V2 only: mask which forbids some particular tokens
    uint8 maxEnabledTokensLength; // V2 only: in V1 as many tokens as the CM can support (256)
    uint16 feeInterest; // Interest fee protocol charges: fee = interest accrues * feeInterest
    uint16 feeLiquidation; // Liquidation fee protocol charges: fee = totalValue * feeLiquidation
    uint16 liquidationDiscount; // Miltiplier to get amount which liquidator should pay: amount = totalValue * liquidationDiscount
    uint16 feeLiquidationExpired; // Liquidation fee protocol charges on expired accounts
    uint16 liquidationDiscountExpired; // Multiplier for the amount the liquidator has to pay when closing an expired account
    // V3 Fileds
    QuotaInfo[] quotas;
}

struct CreditManagerDebtParams {
    address creditManager;
    uint256 borrowed;
    uint256 limit;
    uint256 availableToBorrow;
}

struct PoolData {
    address addr;
    address underlying;
    address dieselToken;
    ///
    uint256 linearCumulativeIndex;
    uint256 availableLiquidity;
    uint256 expectedLiquidity;
    //
    uint256 totalBorrowed;
    uint256 totalDebtLimit;
    CreditManagerDebtParams[] creditManagerDebtParams;
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 supplyRate;
    uint256 baseInterestRate;
    uint256 dieselRate_RAY;
    uint256 withdrawFee;
    uint256 cumulativeIndex_RAY;
    uint256 baseInterestIndexLU;
    uint256 version;
    QuotaInfo[] quotas;
}

struct GaugeQuotaParams {
    address token;
    uint16 minRate;
    uint16 maxRate;
    uint96 totalVotesLpSide;
    uint96 totalVotesCaSide;
    uint16 rate;
    uint16 quotaIncreaseFee;
    uint96 totalQuoted;
    uint96 limit;
}

struct GaugeInfo {
    address addr;
    GaugeQuotaParams[] quotaParams;
}

struct GaugeVote {
    address gauge;
    address token;
    uint96 totalVotesLpSide;
    uint96 totalVotesCaSide;
}
