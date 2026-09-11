// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.23;

import {WithdrawalCompressor} from "../../compressors/WithdrawalCompressor.sol";

contract WithdrawalCompressorHarness is WithdrawalCompressor {
    constructor(address owner_, address addressProvider_) WithdrawalCompressor(owner_, addressProvider_) {}

    function getCompressorForToken(address token) external view returns (address) {
        return _getCompressorForToken(token);
    }
}
