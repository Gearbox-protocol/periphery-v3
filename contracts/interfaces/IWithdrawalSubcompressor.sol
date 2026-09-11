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

interface IWithdrawalSubcompressor is IVersion {
    function getWithdrawableAssets(address creditManager, address token)
        external
        view
        returns (WithdrawableAsset[] memory);

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory);

    function getExternalAccountCurrentWithdrawals(address account, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory);

    function getWithdrawalRequestResult(address creditAccount, address token, address withdrawalToken, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory);

    function getWithdrawalRequestResult(
        address creditAccount,
        address token,
        address withdrawalToken,
        uint256 amount,
        bytes memory extraData
    ) external view returns (RequestableWithdrawal memory);

    function getWithdrawalStatus(address redeemer) external view returns (WithdrawalStatus);
}
