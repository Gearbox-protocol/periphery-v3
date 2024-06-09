// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

/// @notice Credit account data
/// @param  creditAccount Credit account address
/// @param  creditManager Credit manager account is opened in
/// @param  creditFacade Facade connected to account's credit manager
/// @param  underlying Credit manager's underlying token
/// @param  owner Credit account's owner
/// @param  enabledTokensMask Bitmask of tokens enabled on credit account as collateral
/// @param  debt Credit account's debt principal in underlying
/// @param  accruedInterest Base and quota interest accrued on the credit account
/// @param  accruedFees Fees accrued on the credit account
/// @param  totalDebtUSD Account's total debt in USD
/// @param  totalValueUSD Account's total value in USD
/// @param  twvUSD Account's threshold-weighted value in USD
/// @param  totalValue Account's total value in underlying
/// @param  healthFactor Account's health factor, i.e. ratio of `twvUSD` to `totalDebtUSD`, in bps
/// @param  success Whether collateral calculation was successful
/// @param  tokens Info on credit account's enabled tokens and tokens with non-zero balance, see `TokenInfo`
/// @dev    Fields from `totalDebtUSD` through `healthFactor` are not filled if `success` is `false`
/// @dev    `debt`, `accruedInterest` and `accruedFees` don't account for transfer fees
struct CreditAccountData {
    address creditAccount;
    address creditManager;
    address creditFacade;
    address underlying;
    address owner;
    uint256 enabledTokensMask;
    uint256 debt;
    uint256 accruedInterest;
    uint256 accruedFees;
    uint256 totalDebtUSD;
    uint256 totalValueUSD;
    uint256 twvUSD;
    uint256 totalValue;
    uint16 healthFactor;
    bool success;
    TokenInfo[] tokens;
}

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
/// @param  curator If set, match credit managers managed by given curator
/// @param  pool If set, match credit managers connected to a given pool
/// @param  underlying If set, match credit managers with given underlying
struct CreditManagerFilter {
    address curator;
    address pool;
    address underlying;
}

/// @notice Price feed answer packed in a struct
struct PriceFeedAnswer {
    int256 price;
    uint256 updatedAt;
    bool success;
}

/// @notice Represents an entry in the price feed map of a price oracle
/// @dev    `stalenessPeriod` is always 0 if price oracle's version is below `3_10`
struct PriceFeedMapEntry {
    address token;
    bool reserve;
    address priceFeed;
    uint32 stalenessPeriod;
}

/// @notice Represents a node in the price feed "tree"
/// @param  priceFeed Price feed address
/// @param  decimals Price feed's decimals (might not be equal to 8 for lower-level)
/// @param  priceFeedType Price feed type (same as `PriceFeedType` but annotated as `uint8` to support future types),
///         defaults to `PriceFeedType.CHAINLINK_ORACLE`
/// @param  skipCheck Whether price feed implements its own staleness and sanity check, defaults to `false`
/// @param  updatable Whether it is an on-demand updatable (aka pull) price feed, defaults to `false`
/// @param  specificParams ABI-encoded params specific to this price feed type, filled if price feed implements
///         `IStateSerializerTrait` or there is a state serializer set for this type
/// @param  underlyingFeeds Array of underlying feeds, filled when `priceFeed` is nested
/// @param  underlyingStalenessPeriods Staleness periods of underlying feeds, filled when `priceFeed` is nested
/// @param  answer Price feed answer packed in a struct
struct PriceFeedTreeNode {
    address priceFeed;
    uint8 decimals;
    uint8 priceFeedType;
    bool skipCheck;
    bool updatable;
    bytes specificParams;
    address[] underlyingFeeds;
    uint32[] underlyingStalenessPeriods;
    PriceFeedAnswer answer;
}

/// @notice Info on credit account's holdings of a token
/// @param  token Token address
/// @param  mask Token mask in the credit manager
/// @param  balance Account's balance of token
/// @param  quota Account's quota of token
/// @param  success Whether balance call was successful
struct TokenInfo {
    address token;
    uint256 mask;
    uint256 balance;
    uint256 quota;
    bool success;
}
