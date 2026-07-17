// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2025.
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {IWithdrawalSubcompressor} from "../../../interfaces/IWithdrawalSubcompressor.sol";
import {
    WithdrawalOutput,
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal,
    WithdrawalLib,
    WithdrawalStatus
} from "../../../types/WithdrawalInfo.sol";
import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

import {
    SecuritizeRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedemptionGateway.sol";
import {
    SecuritizeRedemptionPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedemptionPhantomToken.sol";
import {
    ISecuritizeRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/interfaces/securitize/ISecuritizeRedemptionGateway.sol";
import {IRedemptionLogger} from "@gearbox-protocol/integrations-v3/contracts/interfaces/IRedemptionLogger.sol";

import {
    ISecuritizeNAVProvider
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/ISecuritizeNAVProvider.sol";

import {
    SecuritizeRedeemer
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedeemer.sol";

import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

contract SecuritizeRedemptionSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_13;
    bytes32 public constant contractType = "GLOBAL::SECURITIZE_WD_SC";

    function getWithdrawableAssets(address, address token) external view returns (WithdrawableAsset[] memory) {
        address securitizeRedemptionGateway = SecuritizeRedemptionPhantomToken(token).redemptionGateway();

        address asset = ISecuritizeRedemptionGateway(securitizeRedemptionGateway).stableCoinToken();

        address dsToken = ISecuritizeRedemptionGateway(securitizeRedemptionGateway).dsToken();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);

        withdrawableAssets[0] = WithdrawableAsset(dsToken, token, asset, 90 days, 10);

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address securitizeRedemptionGateway = SecuritizeRedemptionPhantomToken(token).redemptionGateway();

        ClaimableWithdrawal[] memory claimableWithdrawals =
            _getClaimableWithdrawals(creditAccount, token, securitizeRedemptionGateway, true);

        PendingWithdrawal[] memory pendingWithdrawals =
            _getPendingWithdrawals(creditAccount, securitizeRedemptionGateway);

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
        address securitizeRedemptionGateway = SecuritizeRedemptionPhantomToken(token).redemptionGateway();

        ClaimableWithdrawal[] memory claimableWithdrawals =
            _getClaimableWithdrawals(account, token, securitizeRedemptionGateway, false);

        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(account, securitizeRedemptionGateway);

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
        address securitizeRedemptionGateway = SecuritizeRedemptionPhantomToken(withdrawalToken).redemptionGateway();

        address securitizeRedemptionGatewayAdapter = ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager())
            .contractToAdapter(securitizeRedemptionGateway);

        address stableCoinToken = ISecuritizeRedemptionGateway(securitizeRedemptionGateway).stableCoinToken();

        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;
        requestableWithdrawal.outputs = new WithdrawalOutput[](1);
        requestableWithdrawal.claimableAt = block.timestamp + 90 days;
        requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, 0);
        requestableWithdrawal.requestCalls = new MultiCall[](1);

        requestableWithdrawal.requestCalls[0] = MultiCall(
            address(securitizeRedemptionGatewayAdapter),
            abi.encodeWithSelector(bytes4(keccak256("redeem(uint256,bytes)")), amount, extraData)
        );

        requestableWithdrawal.outputs[0].amount =
            _getRedemptionValue(amount, securitizeRedemptionGateway, token, stableCoinToken);

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address creditAccount, address redemptionGateway)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address stableCoinToken = ISecuritizeRedemptionGateway(redemptionGateway).stableCoinToken();
        address dsToken = ISecuritizeRedemptionGateway(redemptionGateway).dsToken();

        address[] memory redeemers =
            ISecuritizeRedemptionGateway(redemptionGateway).getUnclaimedRedeemers(creditAccount);

        uint256 redeemerCount = 0;

        for (uint256 i = 0; i < redeemers.length; i++) {
            if (!_isRedeemerClaimable(redeemers[i], stableCoinToken)) redeemerCount++;
        }

        pendingWithdrawals = new PendingWithdrawal[](redeemerCount);

        redeemerCount = 0;

        for (uint256 i = 0; i < redeemers.length; i++) {
            if (!_isRedeemerClaimable(redeemers[i], stableCoinToken)) {
                address redeemer = redeemers[i];
                pendingWithdrawals[redeemerCount].token = dsToken;
                pendingWithdrawals[redeemerCount].expectedOutputs = new WithdrawalOutput[](1);

                uint256 redemptionValue = SecuritizeRedeemer(redeemer).getCurrentRedemptionValue();
                pendingWithdrawals[redeemerCount].expectedOutputs[0] =
                    WithdrawalOutput(stableCoinToken, false, redemptionValue);

                uint256 startingTimestamp = SecuritizeRedeemer(redeemer).startingTimestamp();
                pendingWithdrawals[redeemerCount].claimableAt =
                    block.timestamp > startingTimestamp + 90 days ? block.timestamp : startingTimestamp + 90 days;
                pendingWithdrawals[redeemerCount].extraData = _getRedemptionExtraData(redemptionGateway, redeemer);
                redeemerCount++;
            }
        }

        return pendingWithdrawals;
    }

    function _getClaimableWithdrawals(
        address account,
        address withdrawalToken,
        address redemptionGateway,
        bool isCreditAccount
    ) internal view returns (ClaimableWithdrawal[] memory withdrawals) {
        address stableCoinToken = ISecuritizeRedemptionGateway(redemptionGateway).stableCoinToken();
        address dsToken = ISecuritizeRedemptionGateway(redemptionGateway).dsToken();

        address[] memory redeemers = ISecuritizeRedemptionGateway(redemptionGateway).getRedeemers(account);
        uint256 claimableCount = 0;

        for (uint256 i = 0; i < redeemers.length; i++) {
            if (_isClaimableRedeemer(redeemers[i], stableCoinToken)) claimableCount++;
        }

        withdrawals = new ClaimableWithdrawal[](claimableCount);
        if (claimableCount == 0) return withdrawals;

        address claimTarget = isCreditAccount
            ? ICreditManagerV3(ICreditAccountV3(account).creditManager()).contractToAdapter(redemptionGateway)
            : redemptionGateway;

        uint256 idx = 0;

        for (uint256 i = 0; i < redeemers.length; i++) {
            address redeemer = redeemers[i];
            if (!_isClaimableRedeemer(redeemer, stableCoinToken)) continue;

            uint256 stableCoinAmount = IERC20(stableCoinToken).balanceOf(redeemer);

            withdrawals[idx].token = dsToken;
            withdrawals[idx].withdrawalPhantomToken = withdrawalToken;
            withdrawals[idx].withdrawalTokenSpent = SecuritizeRedeemer(redeemer).getRedemptionAmount();
            withdrawals[idx].outputs = new WithdrawalOutput[](1);
            withdrawals[idx].outputs[0] = WithdrawalOutput(stableCoinToken, false, stableCoinAmount);
            withdrawals[idx].claimCalls = new MultiCall[](1);

            address[] memory claimableRedeemers = new address[](1);
            claimableRedeemers[0] = redeemer;
            withdrawals[idx].claimCalls[0] =
                MultiCall(claimTarget, abi.encodeCall(ISecuritizeRedemptionGateway.claim, (claimableRedeemers)));
            withdrawals[idx].extraData = _getRedemptionExtraData(redemptionGateway, redeemer);
            idx++;
        }
    }

    function getWithdrawalStatus(address redeemer) external view returns (WithdrawalStatus) {
        address stableCoinToken = SecuritizeRedeemer(redeemer).stableCoinToken();
        if (_isClaimableRedeemer(redeemer, stableCoinToken)) return WithdrawalStatus.CLAIMABLE;
        if (SecuritizeRedeemer(redeemer).pendingDsTokenAmount() > 0) return WithdrawalStatus.PENDING;

        return WithdrawalStatus.CLAIMED;
    }

    function _isSecuritizeRedeemer(address redeemer) internal view returns (bool) {
        (bool success, bytes memory data) = redeemer.staticcall(abi.encodeWithSignature("gateway()"));
        return success && data.length == 32 && abi.decode(data, (address)) != address(0);
    }

    function _isClaimableRedeemer(address redeemer, address stableCoinToken) internal view returns (bool) {
        return _isRedeemerClaimable(redeemer, stableCoinToken)
            || (SecuritizeRedeemer(redeemer).pendingDsTokenAmount() == 0
                && IERC20(stableCoinToken).balanceOf(redeemer) > 1);
    }

    function _getRedemptionExtraData(address redemptionGateway, address redeemer)
        internal
        view
        returns (bytes memory extraData)
    {
        address redemptionLogger = ISecuritizeRedemptionGateway(redemptionGateway).redemptionLogger();
        if (redemptionLogger == address(0)) return extraData;
        return IRedemptionLogger(redemptionLogger).redemptionLogs(redeemer).extraData;
    }

    function _getRedemptionValue(
        uint256 amount,
        address securitizeRedemptionGateway,
        address dsToken,
        address stableCoinToken
    ) internal view returns (uint256) {
        address navProvider = ISecuritizeRedemptionGateway(securitizeRedemptionGateway).navProvider();
        uint256 currentNavRate = ISecuritizeNAVProvider(navProvider).rate();
        uint256 dsTokenDecimalsMultiplier = 10 ** IERC20Metadata(dsToken).decimals();
        uint256 stableCoinTokenDecimalsMultiplier = 10 ** IERC20Metadata(stableCoinToken).decimals();
        return amount * currentNavRate * stableCoinTokenDecimalsMultiplier
            / (dsTokenDecimalsMultiplier * dsTokenDecimalsMultiplier);
    }

    function _isRedeemerClaimable(address redeemer, address stableCoinToken) internal view returns (bool) {
        uint256 actualAmount = IERC20(stableCoinToken).balanceOf(redeemer);
        uint256 minimumAmount = SecuritizeRedeemer(redeemer).getRedemptionAmount();
        return actualAmount >= minimumAmount;
    }
}
