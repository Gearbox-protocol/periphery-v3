// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

struct PriceOracleState {
    address addr;
    uint256 version;
    PriceFeedMapEntry priceFeedMapping;
    PriceFeedTreeNode priceFeedStructure;
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
/// @param  version Price feed version
/// @param  skipCheck Whether price feed implements its own staleness and sanity check, defaults to `false`
/// @param  updatable Whether it is an on-demand updatable (aka pull) price feed, defaults to `false`
/// @param  specificParams ABI-encoded params specific to this price feed type, filled if price feed implements
///         `IStateSerializer` or there is a state serializer set for this type
/// @param  underlyingFeeds Array of underlying feeds, filled when `priceFeed` is nested
/// @param  underlyingStalenessPeriods Staleness periods of underlying feeds, filled when `priceFeed` is nested
/// @param  answer Price feed answer packed in a struct
struct PriceFeedTreeNode {
    address priceFeed;
    uint8 decimals;
    uint8 priceFeedType;
    uint256 version;
    bool skipCheck;
    bool updatable;
    bytes specificParams;
    address[] underlyingFeeds;
    uint32[] underlyingStalenessPeriods;
    PriceFeedAnswer answer;
}
