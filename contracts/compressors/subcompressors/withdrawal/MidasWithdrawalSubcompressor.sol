// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2025.
pragma solidity ^0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {IWithdrawalSubcompressor} from "../../../interfaces/IWithdrawalSubcompressor.sol";

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

import {MidasGateway} from "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasGateway.sol";
import {
    MidasRedemptionVaultPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasRedemptionVaultPhantomToken.sol";
import {MidasRedeemer} from "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasRedeemer.sol";

import {
    IMidasRedemptionVault
} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/IMidasRedemptionVault.sol";
import {IMidasGateway} from "@gearbox-protocol/integrations-v3/contracts/interfaces/midas/IMidasGateway.sol";
import {IRedemptionLogger} from "@gearbox-protocol/integrations-v3/contracts/interfaces/IRedemptionLogger.sol";

import {
    WithdrawalLib,
    WithdrawalOutput,
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal,
    WithdrawalStatus
} from "../../../types/WithdrawalInfo.sol";

import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

interface IMidasDataFeed {
    function getDataInBase18() external view returns (uint256);
}

interface IMidasRedemptionVaultTokensConfig {
    function tokensConfig(address token)
        external
        view
        returns (address dataFeed, uint256 fee, uint256 allowance, bool stable);
}

contract MidasWithdrawalSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_13;
    bytes32 public constant contractType = "GLOBAL::MIDAS_WD_SC";

    function getWithdrawableAssets(address, address token) external view returns (WithdrawableAsset[] memory) {
        address gateway = MidasRedemptionVaultPhantomToken(token).gateway();

        address asset = MidasRedemptionVaultPhantomToken(token).underlying();

        address mToken = MidasGateway(gateway).mToken();
        uint256 expectedRedemptionDuration = MidasGateway(gateway).expectedRedemptionDuration();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);

        withdrawableAssets[0] = WithdrawableAsset(mToken, token, asset, expectedRedemptionDuration, 10);

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address gateway = MidasRedemptionVaultPhantomToken(token).gateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = _getClaimableWithdrawals(creditAccount, gateway, token, true);

        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(creditAccount, gateway);

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
        address gateway = MidasRedemptionVaultPhantomToken(token).gateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = _getClaimableWithdrawals(account, gateway, token, false);
        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(account, gateway);

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
        address gateway = MidasRedemptionVaultPhantomToken(withdrawalToken).gateway();

        address gatewayAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(gateway);

        address quoteToken = MidasGateway(gateway).quoteToken();

        uint256 outputAmount;

        {
            uint256 mTokenRate = _getMTokenRate(gateway);
            uint256 tokenOutRate = _getTokenOutRate(gateway, quoteToken);
            if (mTokenRate == 0 || tokenOutRate == 0) return requestableWithdrawal;

            outputAmount = _convertToDecimals(
                mTokenRate * _getAmountAfterFee(gateway, quoteToken, amount) / tokenOutRate, quoteToken
            );
        }

        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;
        requestableWithdrawal.outputs = new WithdrawalOutput[](1);

        requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, outputAmount);
        requestableWithdrawal.requestCalls = new MultiCall[](1);
        requestableWithdrawal.requestCalls[0] = MultiCall(
            address(gatewayAdapter),
            abi.encodeWithSelector(bytes4(keccak256("redeemRequest(uint256,bytes)")), amount, extraData)
        );

        requestableWithdrawal.claimableAt = block.timestamp + MidasGateway(gateway).expectedRedemptionDuration();

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address creditAccount, address gateway)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address mToken = MidasGateway(gateway).mToken();
        address quoteToken = MidasGateway(gateway).quoteToken();
        uint256 expectedRedemptionDuration = MidasGateway(gateway).expectedRedemptionDuration();

        address[] memory redeemers = MidasGateway(gateway).pendingRedeemers(creditAccount);
        uint256 nPending = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            if (MidasRedeemer(redeemers[i]).pendingTokenOutAmount() > 0) nPending++;
        }

        pendingWithdrawals = new PendingWithdrawal[](nPending);

        nPending = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            address redeemer = redeemers[i];

            uint256 pendingTokenOutAmount = MidasRedeemer(redeemer).pendingTokenOutAmount();
            if (pendingTokenOutAmount > 0) {
                pendingWithdrawals[nPending].token = mToken;
                pendingWithdrawals[nPending].expectedOutputs = new WithdrawalOutput[](1);
                pendingWithdrawals[nPending].expectedOutputs[0] =
                    WithdrawalOutput(quoteToken, false, pendingTokenOutAmount);
                pendingWithdrawals[nPending].claimableAt =
                    MidasRedeemer(redeemer).redemptionStartTimestamp() + expectedRedemptionDuration;
                pendingWithdrawals[nPending].extraData = _getRedemptionExtraData(gateway, redeemer);
                nPending++;
            }
        }

        return pendingWithdrawals;
    }

    function _getClaimableWithdrawals(
        address account,
        address gateway,
        address withdrawalToken,
        bool isCreditAccount
    ) internal view returns (ClaimableWithdrawal[] memory withdrawals) {
        address mToken = MidasGateway(gateway).mToken();
        address quoteToken = MidasGateway(gateway).quoteToken();

        address claimTarget = isCreditAccount
            ? ICreditManagerV3(ICreditAccountV3(account).creditManager()).contractToAdapter(gateway)
            : gateway;

        address[] memory redeemers = MidasGateway(gateway).pendingRedeemers(account);
        uint256 claimableCount = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            if (MidasRedeemer(redeemers[i]).claimableTokenOutAmount() > 0) {
                claimableCount++;
            }
        }

        withdrawals = new ClaimableWithdrawal[](claimableCount);
        uint256 idx = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            address redeemer = redeemers[i];
            uint256 claimableAmount = MidasRedeemer(redeemer).claimableTokenOutAmount();
            if (claimableAmount == 0) continue;

            withdrawals[idx].token = mToken;
            withdrawals[idx].withdrawalPhantomToken = withdrawalToken;
            withdrawals[idx].withdrawalTokenSpent = claimableAmount;
            withdrawals[idx].outputs = new WithdrawalOutput[](1);
            withdrawals[idx].outputs[0] = WithdrawalOutput(quoteToken, false, claimableAmount);
            withdrawals[idx].claimCalls = new MultiCall[](1);
            withdrawals[idx].claimCalls[0] = MultiCall(
                claimTarget, abi.encodeCall(IMidasGateway.withdrawFromRedeemer, (redeemer, claimableAmount))
            );
            withdrawals[idx].extraData = _getRedemptionExtraData(gateway, redeemer);
            idx++;
        }
    }

    function getWithdrawalStatus(address redeemer) external view returns (WithdrawalStatus) {
        if (MidasRedeemer(redeemer).pendingTokenOutAmount() > 0) return WithdrawalStatus.PENDING;
        if (MidasRedeemer(redeemer).claimableTokenOutAmount() > 0) return WithdrawalStatus.CLAIMABLE;

        return WithdrawalStatus.CLAIMED;
    }

    function _isMidasRedeemer(address redeemer) internal view returns (bool) {
        (bool success, bytes memory data) = redeemer.staticcall(abi.encodeWithSignature("gateway()"));
        return success && data.length == 32 && abi.decode(data, (address)) != address(0);
    }

    function _getRedemptionExtraData(address gateway, address redeemer) internal view returns (bytes memory extraData) {
        address redemptionLogger = IMidasGateway(gateway).redemptionLogger();
        if (redemptionLogger == address(0)) return extraData;
        return IRedemptionLogger(redemptionLogger).redemptionLogs(redeemer).extraData;
    }

    function _getMTokenRate(address gateway) internal view returns (uint256) {
        address midasRedemptionVault = MidasGateway(gateway).midasRedemptionVault();
        address mTokenDataFeed = IMidasRedemptionVault(midasRedemptionVault).mTokenDataFeed();
        try IMidasDataFeed(mTokenDataFeed).getDataInBase18() returns (uint256 rate) {
            return rate;
        } catch {
            return 0;
        }
    }

    function _getTokenOutRate(address gateway, address quoteToken) internal view returns (uint256) {
        address midasRedemptionVault = MidasGateway(gateway).midasRedemptionVault();
        (address dataFeed,,, bool stable) =
            IMidasRedemptionVaultTokensConfig(midasRedemptionVault).tokensConfig(quoteToken);
        if (stable) {
            return WAD;
        } else {
            try IMidasDataFeed(dataFeed).getDataInBase18() returns (uint256 rate) {
                return rate;
            } catch {
                return 0;
            }
        }
    }

    function _convertToDecimals(uint256 amount, address token) internal view returns (uint256) {
        uint256 tokenUnit = 10 ** IERC20Metadata(token).decimals();
        return amount * tokenUnit / WAD;
    }

    function _getAmountAfterFee(address gateway, address quoteToken, uint256 amount) internal view returns (uint256) {
        address midasRedemptionVault = MidasGateway(gateway).midasRedemptionVault();
        (, uint256 fee,,) = IMidasRedemptionVaultTokensConfig(midasRedemptionVault).tokensConfig(quoteToken);
        return amount * (1e5 - fee) / 1e5;
    }
}
