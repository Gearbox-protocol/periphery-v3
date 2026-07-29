// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";
import {LiquidationData} from "../types/LiquidationInfo.sol";

interface ILiquidationCompressor is IVersion {
    function getLiquidationData(address liquidator, address creditAccount, PriceUpdate[] calldata priceUpdates)
        external
        returns (LiquidationData memory);
}
