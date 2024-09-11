// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {TokenInfo} from "../types/MarketData.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LibString} from "@solady/utils/LibString.sol";

contract TokenCompressor {
    function getTokenInfo(address token) public view returns (TokenInfo memory result) {
        result.token = token;
        result.decimals = IERC20Metadata(token).decimals();

        // Fallback to low-level call to handle bytes32 symbol
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("symbol()"));
        if (success) {
            if (data.length == 32) {
                result.symbol = LibString.fromSmallString(bytes32(data));
            } else {
                result.symbol = abi.decode(data, (string));
            }
        } else {
            revert("symbol retrieval failed");
        }

        (success, data) = token.staticcall(abi.encodeWithSignature("name()"));
        if (success) {
            if (data.length == 32) {
                result.name = LibString.fromSmallString(bytes32(data));
            } else {
                result.name = abi.decode(data, (string));
            }
        } else {
            revert("name retrieval failed");
        }
    }
}
