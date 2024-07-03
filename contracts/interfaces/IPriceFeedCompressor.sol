// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.10;

import {PriceFeedAnswer, PriceFeedMapEntry, PriceFeedTreeNode} from "../types/PriceOracleState.sol";

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

interface IPriceFeedCompressor is IVersion {
    /// @notice Emitted when new state serializer is set for a given price feed type
    event SetSerializer(uint8 indexed priceFeedType, address indexed serializer);

    function getPriceFeeds(address priceOracle)
        external
        view
        returns (PriceFeedMapEntry[] memory priceFeedMap, PriceFeedTreeNode[] memory priceFeedTree);

    function getPriceFeeds(address priceOracle, address[] memory tokens)
        external
        view
        returns (PriceFeedMapEntry[] memory priceFeedMap, PriceFeedTreeNode[] memory priceFeedTree);

    function loadPriceFeedTree(address[] memory priceFeeds)
        external
        view
        returns (PriceFeedTreeNode[] memory priceFeedTree);
}
