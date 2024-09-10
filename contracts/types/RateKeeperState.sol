// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {BaseParams} from "./BaseState.sol";

struct RateKeeperState {
    BaseParams baseParams;
    Rate[] rates;
}

struct Rate {
    address token;
    uint16 rate;
}

struct GaugeInfo {
    address voter;
    uint16 epochLastUpdate;
    bool epochFrozen;
    GaugeQuotaParams[] quotaParams;
}

struct GaugeQuotaParams {
    address token;
    uint16 minRate;
    uint16 maxRate;
    uint96 totalVotesLpSide;
    uint96 totalVotesCaSide;
}
