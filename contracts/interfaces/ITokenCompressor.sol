// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.10;

import {TokenData} from "../types/TokenData.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

/// @title Token compressor 3.0.
/// @notice Helper contract to fetch ERC20 token metadata
interface ITokenCompressor is IVersion {
    function getTokenInfo(address token) external view returns (TokenData memory result);
}
