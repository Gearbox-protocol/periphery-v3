// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2024.
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {BotState, ZapperState} from "../types/PeripheryState.sol";

interface IPeripheryCompressor is IVersion {
    function getZappers(address marketConfigurator, address pool) external view returns (ZapperState[] memory);

    function getActiveBots(address marketConfigurator, address creditAccount)
        external
        view
        returns (BotState[] memory);
}
