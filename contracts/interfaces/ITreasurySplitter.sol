// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "./IVersion.sol";
import {IStateSerializer} from "./IStateSerializer.sol";

interface ITreasurySplitter is IVersion, IStateSerializer {}
