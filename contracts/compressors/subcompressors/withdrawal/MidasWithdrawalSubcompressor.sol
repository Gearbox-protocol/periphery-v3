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
import {
    IMidasGatewayAdapter
} from "@gearbox-protocol/integrations-v3/contracts/interfaces/midas/IMidasGatewayAdapter.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {
    WithdrawalLib,
    WithdrawalOutput,
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal
} from "../../../types/WithdrawalInfo.sol";

import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

interface IMidasDataFeed {
    function getDataInBase18() external view returns (uint256);
}

interface IMidasRedemptionVaultExt {
    function mTokenDataFeed() external view returns (address);
    function tokensConfig(address token)
        external
        view
        returns (address dataFeed, uint256 fee, uint256 allowance, bool stable);
}

contract MidasWithdrawalSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_12;
    bytes32 public constant contractType = "GLOBAL::MIDAS_WD_SC";

    function getWithdrawableAssets(address, address token) external view returns (WithdrawableAsset[] memory) {
        address gateway = MidasRedemptionVaultPhantomToken(token).gateway();

        address asset = MidasRedemptionVaultPhantomToken(token).tokenOut();

        address mToken = MidasGateway(gateway).mToken();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);

        withdrawableAssets[0] = WithdrawableAsset(mToken, token, asset, 2 days, 10);

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address gateway = MidasRedemptionVaultPhantomToken(token).gateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](1);
        claimableWithdrawals[0] = _getClaimableWithdrawal(creditAccount, gateway, token);

        if (claimableWithdrawals[0].outputs.length == 0 || claimableWithdrawals[0].outputs[0].amount == 0) {
            claimableWithdrawals = new ClaimableWithdrawal[](0);
        }

        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(creditAccount, gateway);

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
        address gateway = MidasRedemptionVaultPhantomToken(withdrawalToken).gateway();

        address gatewayAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(gateway);

        address asset = MidasRedemptionVaultPhantomToken(withdrawalToken).tokenOut();

        uint256 outputAmount;

        {
            uint256 mTokenRate = _getMTokenRate(gateway);
            uint256 tokenOutRate = _getTokenOutRate(gateway, asset);
            if (mTokenRate == 0 || tokenOutRate == 0) return requestableWithdrawal;

            outputAmount =
                _convertToDecimals(mTokenRate * _getAmountAfterFee(gateway, asset, amount) / tokenOutRate, asset);
        }

        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;
        requestableWithdrawal.outputs = new WithdrawalOutput[](1);

        requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, outputAmount);
        requestableWithdrawal.requestCalls = new MultiCall[](1);
        requestableWithdrawal.requestCalls[0] =
            MultiCall(address(gatewayAdapter), abi.encodeCall(IMidasGatewayAdapter.redeemRequest, (asset, amount)));

        requestableWithdrawal.claimableAt = block.timestamp + 2 days;

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address creditAccount, address gateway)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address mToken = MidasGateway(gateway).mToken();
        address midasRedemptionVault = MidasGateway(gateway).midasRedemptionVault();
        uint256 expectedRedemptionDuration = MidasGateway(gateway).expectedRedemptionDuration();

        address[] memory redeemers = MidasGateway(gateway).pendingRedeemers(creditAccount);
        uint256 nPending = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            uint256 requestId = MidasRedeemer(redeemers[i]).requestId();

            (, address requestTokenOut,,,,) = IMidasRedemptionVault(midasRedemptionVault).redeemRequests(requestId);

            if (MidasRedeemer(redeemers[i]).pendingTokenOutAmount(requestTokenOut) > 0) nPending++;
        }

        pendingWithdrawals = new PendingWithdrawal[](nPending);

        nPending = 0;

        for (uint256 i = 0; i < redeemers.length; ++i) {
            address redeemer = redeemers[i];

            uint256 requestId = MidasRedeemer(redeemer).requestId();
            (, address requestTokenOut,,,,) = IMidasRedemptionVault(midasRedemptionVault).redeemRequests(requestId);

            uint256 pendingTokenOutAmount = MidasRedeemer(redeemer).pendingTokenOutAmount(requestTokenOut);
            if (pendingTokenOutAmount > 0) {
                pendingWithdrawals[nPending].token = mToken;
                pendingWithdrawals[nPending].expectedOutputs = new WithdrawalOutput[](1);
                pendingWithdrawals[nPending].expectedOutputs[0] =
                    WithdrawalOutput(requestTokenOut, false, pendingTokenOutAmount);
                pendingWithdrawals[nPending].claimableAt =
                    MidasRedeemer(redeemer).redemptionStartTimestamp() + expectedRedemptionDuration;
                nPending++;
            }
        }

        return pendingWithdrawals;
    }

    function _getClaimableWithdrawal(address creditAccount, address gateway, address withdrawalToken)
        internal
        view
        returns (ClaimableWithdrawal memory withdrawal)
    {
        address mToken = MidasGateway(gateway).mToken();

        address tokenOut = MidasRedemptionVaultPhantomToken(withdrawalToken).tokenOut();

        address gatewayAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(gateway);

        (, uint256 claimableAmount) = MidasGateway(gateway).pendingAndClaimableTokenOutAmounts(creditAccount, tokenOut);

        withdrawal.token = mToken;
        withdrawal.outputs = new WithdrawalOutput[](1);
        withdrawal.outputs[0] = WithdrawalOutput(tokenOut, false, claimableAmount);

        withdrawal.claimCalls = new MultiCall[](1);
        withdrawal.claimCalls[0] =
            MultiCall(address(gatewayAdapter), abi.encodeCall(IMidasGatewayAdapter.withdraw, (tokenOut, claimableAmount)));
        withdrawal.withdrawalPhantomToken = withdrawalToken;
        withdrawal.withdrawalTokenSpent = claimableAmount;

        return withdrawal;
    }

    function _getMTokenRate(address gateway) internal view returns (uint256) {
        address midasRedemptionVault = MidasGateway(gateway).midasRedemptionVault();
        address mTokenDataFeed = IMidasRedemptionVaultExt(midasRedemptionVault).mTokenDataFeed();
        try IMidasDataFeed(mTokenDataFeed).getDataInBase18() returns (uint256 rate) {
            return rate;
        } catch {
            return 0;
        }
    }

    function _getTokenOutRate(address gateway, address asset) internal view returns (uint256) {
        address midasRedemptionVault = MidasGateway(gateway).midasRedemptionVault();
        (address dataFeed,,, bool stable) = IMidasRedemptionVaultExt(midasRedemptionVault).tokensConfig(asset);
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

    function _getAmountAfterFee(address gateway, address asset, uint256 amount) internal view returns (uint256) {
        address midasRedemptionVault = MidasGateway(gateway).midasRedemptionVault();
        (, uint256 fee,,) = IMidasRedemptionVaultExt(midasRedemptionVault).tokensConfig(asset);
        return amount * (1e5 - fee) / 1e5;
    }
}
