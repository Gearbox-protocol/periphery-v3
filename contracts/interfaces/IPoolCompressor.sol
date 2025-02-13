// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {BaseState} from "../types/BaseState.sol";
import {PoolQuotaKeeperState} from "../types/PoolQuotaKeeperState.sol";
import {PoolState} from "../types/PoolState.sol";
import {RateKeeperState} from "../types/RateKeeperState.sol";

interface IPoolCompressor is IVersion {
    function getPoolState(address pool) external view returns (PoolState memory);

    function getPoolQuotaKeeperState(address quotaKeeper) external view returns (PoolQuotaKeeperState memory);

    function getRateKeeperState(address rateKeeper) external view returns (RateKeeperState memory);

    function getInterestRateModelState(address interestRateModel) external view returns (BaseState memory);

    function getLossPolicyState(address lossPolicy) external view returns (BaseState memory);
}
