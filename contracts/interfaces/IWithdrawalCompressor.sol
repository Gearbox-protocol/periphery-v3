// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal,
    WithdrawalStatus
} from "../types/WithdrawalInfo.sol";

interface IWithdrawalCompressor is IVersion {
    function getWithdrawableAssets(address creditManager) external view returns (WithdrawableAsset[] memory);

    function getCurrentWithdrawals(address creditAccount)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory);

    function getExternalAccountCurrentWithdrawals(address withdrawalToken, address account)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory);

    function getExternalAccountCurrentWithdrawals(address[] memory withdrawalTokens, address account)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory);

    function getWithdrawalRequestResult(address creditAccount, address token, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory);

    function getWithdrawalRequestResult(address creditAccount, address token, address withdrawalToken, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory);

    function getWithdrawalRequestResult(
        address creditAccount,
        address token,
        address withdrawalToken,
        uint256 amount,
        bytes calldata extraData
    ) external view returns (RequestableWithdrawal memory);

    function getWithdrawalStatus(address redeemer) external view returns (WithdrawalStatus);

    function getWithdrawalStatus(address[] memory redeemers) external view returns (WithdrawalStatus[] memory);
}
