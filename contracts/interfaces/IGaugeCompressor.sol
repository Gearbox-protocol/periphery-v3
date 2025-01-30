// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.10;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {MarketFilter} from "../types/Filters.sol";
import {GaugeQuotaParams, GaugeInfo} from "../types/RateKeeperState.sol";

interface IGaugeCompressor is IVersion {
    function getGauges(MarketFilter memory filter, address staker) external view returns (GaugeInfo[] memory result);

    function getGauge(address gauge, address staker) external view returns (GaugeInfo memory result);
}
