// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.23;

import {IWithdrawalSubcompressor} from "../../../interfaces/IWithdrawalSubcompressor.sol";
import {
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal
} from "../../../types/WithdrawalInfo.sol";

contract MockWithdrawalSubcompressor is IWithdrawalSubcompressor {
    uint256 public immutable override version;
    bytes32 public immutable override contractType;

    constructor(bytes32 cType_, uint256 version_) {
        contractType = cType_;
        version = version_;
    }

    function getWithdrawableAssets(address, address) external pure returns (WithdrawableAsset[] memory assets) {
        return assets;
    }

    function getCurrentWithdrawals(address, address)
        external
        pure
        returns (ClaimableWithdrawal[] memory claimable, PendingWithdrawal[] memory pending)
    {
        return (claimable, pending);
    }

    function getWithdrawalRequestResult(address, address, address, uint256)
        external
        pure
        returns (RequestableWithdrawal memory withdrawal)
    {
        return withdrawal;
    }

    function getWithdrawalRequestResult(address, address, address, uint256, bytes memory)
        external
        pure
        returns (RequestableWithdrawal memory withdrawal)
    {
        return withdrawal;
    }
}
