// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {TokenData} from "../types/TokenData.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {ITokenCompressor} from "../interfaces/ITokenCompressor.sol";

address constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

/// @title Token compressor 3.0.
/// @notice Helper contract to fetch ERC20 token metadata
contract TokenCompressor is ITokenCompressor {
    /// @notice Contract version
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "TOKEN_COMPRESSOR";

    function getTokenInfo(address token) public view returns (TokenData memory result) {
        if (token == ETH_ADDRESS) {
            return TokenData({addr: ETH_ADDRESS, decimals: 18, symbol: "ETH", name: "Ether"});
        }

        result.addr = token;
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
