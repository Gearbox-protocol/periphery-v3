// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {IWithdrawalSubcompressor} from "../../../interfaces/IWithdrawalSubcompressor.sol";

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

import {
    TreehouseRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/TreehouseRedemptionGateway.sol";
import {
    TreehouseRedemptionPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/TreehouseRedemptionPhantomToken.sol";
import {
    TreehouseRedeemer
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/TreehouseRedeemer.sol";
import {
    ITreehouseRedemptionGateway,
    MAX_PENDING_REDEEMERS_PER_ACCOUNT
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/interfaces/ITreehouseRedemptionGateway.sol";
import {
    ITreehouseRedemptionV3,
    RedemptionInfo,
    FEE_PRECISION
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/interfaces/external/ITreehouseRedemptionV3.sol";
import {
    IWstETH
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/interfaces/external/IWstETH.sol";
import {
    IRedemptionLogger
} from "@gearbox-protocol/integrations-v3/contracts/integrations/common/interfaces/IRedemptionLogger.sol";

import {
    WithdrawalLib,
    WithdrawalOutput,
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal,
    WithdrawalStatus
} from "../../../types/WithdrawalInfo.sol";

contract TreehouseWithdrawalSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "GLOBAL::TREEHOUSE_WD_SC";

    function getWithdrawableAssets(address, address token) external view returns (WithdrawableAsset[] memory) {
        address gateway = TreehouseRedemptionPhantomToken(token).gateway();

        address asset = TreehouseRedemptionPhantomToken(token).underlying();
        address tAsset = TreehouseRedemptionGateway(gateway).tAsset();
        uint256 waitingPeriod =
            ITreehouseRedemptionV3(TreehouseRedemptionGateway(gateway).redemptionV3()).waitingPeriod();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);
        withdrawableAssets[0] =
            WithdrawableAsset(tAsset, token, asset, waitingPeriod, MAX_PENDING_REDEEMERS_PER_ACCOUNT);

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address gateway = TreehouseRedemptionPhantomToken(token).gateway();

        ClaimableWithdrawal[] memory claimableWithdrawals =
            _getClaimableWithdrawals(creditAccount, gateway, token, true);

        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(creditAccount, gateway, true);

        for (uint256 i = 0; i < pendingWithdrawals.length; ++i) {
            pendingWithdrawals[i].withdrawalPhantomToken = token;
        }

        return (claimableWithdrawals, pendingWithdrawals);
    }

    function getExternalAccountCurrentWithdrawals(address account, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address gateway = TreehouseRedemptionPhantomToken(token).gateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = _getClaimableWithdrawals(account, gateway, token, false);
        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(account, gateway, false);

        for (uint256 i = 0; i < pendingWithdrawals.length; ++i) {
            pendingWithdrawals[i].withdrawalPhantomToken = token;
        }

        return (claimableWithdrawals, pendingWithdrawals);
    }

    function getWithdrawalRequestResult(address creditAccount, address token, address withdrawalToken, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory requestableWithdrawal)
    {
        return _getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount, new bytes(0));
    }

    function getWithdrawalRequestResult(
        address creditAccount,
        address token,
        address withdrawalToken,
        uint256 amount,
        bytes memory extraData
    ) external view returns (RequestableWithdrawal memory requestableWithdrawal) {
        return _getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount, extraData);
    }

    function _getWithdrawalRequestResult(
        address creditAccount,
        address token,
        address withdrawalToken,
        uint256 amount,
        bytes memory extraData
    ) internal view returns (RequestableWithdrawal memory requestableWithdrawal) {
        address gateway = TreehouseRedemptionPhantomToken(withdrawalToken).gateway();

        address gatewayAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(gateway);

        address redemptionV3 = TreehouseRedemptionGateway(gateway).redemptionV3();
        address tAsset = TreehouseRedemptionGateway(gateway).tAsset();
        address vaultUnderlying = TreehouseRedemptionGateway(gateway).vaultUnderlying();

        // At request time, Treehouse stores current assets/baseRate as RedemptionInfo, so the redeemer formula
        // reduces to convertToAssets(shares) adjusted by redemptionFee (baseRate mins cancel out).
        uint256 outputAmount = _getRedemptionAmount(
            tAsset,
            vaultUnderlying,
            redemptionV3,
            amount,
            IERC4626(tAsset).convertToAssets(amount),
            IWstETH(vaultUnderlying).stEthPerToken()
        );

        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;
        requestableWithdrawal.outputs = new WithdrawalOutput[](1);
        requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, outputAmount);
        requestableWithdrawal.requestCalls = new MultiCall[](1);
        requestableWithdrawal.requestCalls[0] = MultiCall(
            gatewayAdapter, abi.encodeWithSelector(bytes4(keccak256("redeem(uint256,bytes)")), amount, extraData)
        );
        requestableWithdrawal.claimableAt = block.timestamp + ITreehouseRedemptionV3(redemptionV3).waitingPeriod();

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address account, address gateway, bool isCreditAccount)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address tAsset = TreehouseRedemptionGateway(gateway).tAsset();
        address vaultUnderlying = TreehouseRedemptionGateway(gateway).vaultUnderlying();
        address redemptionV3 = TreehouseRedemptionGateway(gateway).redemptionV3();
        uint256 waitingPeriod = ITreehouseRedemptionV3(redemptionV3).waitingPeriod();

        address[] memory redeemers = isCreditAccount
            ? TreehouseRedemptionGateway(gateway).pendingRedeemers(account)
            : TreehouseRedemptionGateway(gateway).redeemers(account);
        uint256 nPending = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            if (TreehouseRedeemer(redeemers[i]).pendingAmount() > 0) nPending++;
        }

        pendingWithdrawals = new PendingWithdrawal[](nPending);
        nPending = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            address redeemer = redeemers[i];
            uint256 pendingAmount = TreehouseRedeemer(redeemer).pendingAmount();
            if (pendingAmount > 0) {
                RedemptionInfo memory redemptionInfo = ITreehouseRedemptionV3(redemptionV3).getRedeemInfo(redeemer, 0);

                pendingWithdrawals[nPending].token = tAsset;
                pendingWithdrawals[nPending].expectedOutputs = new WithdrawalOutput[](1);
                pendingWithdrawals[nPending].expectedOutputs[0] =
                    WithdrawalOutput(vaultUnderlying, false, pendingAmount);
                pendingWithdrawals[nPending].claimableAt = uint256(redemptionInfo.startTime) + waitingPeriod;
                pendingWithdrawals[nPending].redeemer = redeemer;
                pendingWithdrawals[nPending].extraData = _getRedemptionExtraData(gateway, redeemer);
                nPending++;
            }
        }

        return pendingWithdrawals;
    }

    function _getClaimableWithdrawals(address account, address gateway, address withdrawalToken, bool isCreditAccount)
        internal
        view
        returns (ClaimableWithdrawal[] memory withdrawals)
    {
        address tAsset = TreehouseRedemptionGateway(gateway).tAsset();
        address vaultUnderlying = TreehouseRedemptionGateway(gateway).vaultUnderlying();

        address claimTarget = isCreditAccount
            ? ICreditManagerV3(ICreditAccountV3(account).creditManager()).contractToAdapter(gateway)
            : gateway;

        address[] memory redeemers = isCreditAccount
            ? TreehouseRedemptionGateway(gateway).pendingRedeemers(account)
            : TreehouseRedemptionGateway(gateway).redeemers(account);
        uint256 claimableCount = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            if (TreehouseRedeemer(redeemers[i]).claimableAmount() > 0) {
                claimableCount++;
            }
        }

        withdrawals = new ClaimableWithdrawal[](claimableCount);
        uint256 idx = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            address redeemer = redeemers[i];
            uint256 claimableAmount = TreehouseRedeemer(redeemer).claimableAmount();
            if (claimableAmount == 0) continue;

            withdrawals[idx].token = tAsset;
            withdrawals[idx].withdrawalPhantomToken = withdrawalToken;
            withdrawals[idx].withdrawalTokenSpent = claimableAmount;
            withdrawals[idx].outputs = new WithdrawalOutput[](1);
            withdrawals[idx].outputs[0] = WithdrawalOutput(vaultUnderlying, false, claimableAmount);
            withdrawals[idx].claimCalls = new MultiCall[](1);
            withdrawals[idx].claimCalls[0] =
                MultiCall(claimTarget, abi.encodeCall(ITreehouseRedemptionGateway.finalizeRedeem, (redeemer)));
            withdrawals[idx].redeemer = redeemer;
            withdrawals[idx].extraData = _getRedemptionExtraData(gateway, redeemer);
            idx++;
        }
    }

    function getWithdrawalStatus(address redeemer) external view returns (WithdrawalStatus) {
        if (TreehouseRedeemer(redeemer).pendingAmount() > 0) return WithdrawalStatus.PENDING;
        if (TreehouseRedeemer(redeemer).claimableAmount() > 0) return WithdrawalStatus.CLAIMABLE;

        return WithdrawalStatus.CLAIMED;
    }

    function _getRedemptionExtraData(address gateway, address redeemer) internal view returns (bytes memory extraData) {
        address redemptionLogger = ITreehouseRedemptionGateway(gateway).redemptionLogger();
        if (redemptionLogger == address(0)) return extraData;
        return IRedemptionLogger(redemptionLogger).redemptionLogs(redeemer).extraData;
    }

    /// @dev Mirrors `TreehouseRedeemer._getRedemptionAmount`
    function _getRedemptionAmount(
        address tAsset,
        address vaultUnderlying,
        address redemptionV3,
        uint256 shares,
        uint256 assets,
        uint256 baseRate
    ) internal view returns (uint256) {
        (uint256 currentAssets, uint256 currentBaseRate) = _getCurrentAssetsAndBaseRate(tAsset, vaultUnderlying, shares);

        uint256 amountWithFee =
            Math.min(assets, currentAssets) * Math.min(baseRate, currentBaseRate) / Math.max(baseRate, currentBaseRate);

        uint256 redemptionFee = _getRedemptionFee(redemptionV3);

        return amountWithFee * (FEE_PRECISION - redemptionFee) / FEE_PRECISION;
    }

    /// @dev Mirrors `TreehouseRedeemer._getRedemptionFee`
    function _getRedemptionFee(address redemptionV3) internal view returns (uint32) {
        return ITreehouseRedemptionV3(redemptionV3).redemptionFee() + ITreehouseRedemptionV3(redemptionV3).treasuryFee();
    }

    /// @dev Mirrors `TreehouseRedeemer._getCurrentAssetsAndBaseRate`
    function _getCurrentAssetsAndBaseRate(address tAsset, address vaultUnderlying, uint256 shares)
        internal
        view
        returns (uint256 currentAssets, uint256 currentBaseRate)
    {
        currentAssets = IERC4626(tAsset).convertToAssets(shares);
        currentBaseRate = IWstETH(vaultUnderlying).stEthPerToken();
    }
}
