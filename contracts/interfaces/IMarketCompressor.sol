// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.10;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {BaseParams} from "../types/BaseState.sol";
import {MarketFilter} from "../types/Filters.sol";
import {MarketData} from "../types/MarketData.sol";

interface IMarketCompressor is IVersion {
    function getMarketData(address pool) external view returns (MarketData memory result);

    function getMarketData(address pool, address configurator) external view returns (MarketData memory result);

    function getMarkets(MarketFilter memory filter) external view returns (MarketData[] memory result);

    function getUpdatablePriceFeeds(MarketFilter memory filter)
        external
        view
        returns (BaseParams[] memory updatablePriceFeeds);
}
