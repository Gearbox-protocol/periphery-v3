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
    WithdrawalLib
} from "../../../types/WithdrawalInfo.sol";
import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

import {
    SecuritizeRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedemptionGateway.sol";
import {
    SecuritizeRedemptionGatewayAdapter
} from "@gearbox-protocol/integrations-v3/contracts/adapters/securitize/SecuritizeRedemptionGatewayAdapter.sol";
import {
    SecuritizeRedemptionPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedemptionPhantomToken.sol";
import {
    ISecuritizeRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/interfaces/securitize/ISecuritizeRedemptionGateway.sol";
import {
    ISecuritizeRedemptionGatewayAdapter
} from "@gearbox-protocol/integrations-v3/contracts/interfaces/securitize/ISecuritizeRedemptionGatewayAdapter.sol";

import {
    ISecuritizeNAVProvider
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/ISecuritizeNAVProvider.sol";

import {
    SecuritizeRedeemer
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedeemer.sol";

import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

contract SecuritizeRdemptionSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "GLOBAL::SECURITIZE_WD_SC";

    function getWithdrawableAssets(address, address token)
        external
        view
        returns (WithdrawableAsset[] memory)
    {
        address securitizeRedemptionGateway = SecuritizeRedemptionPhantomToken(token).redemptionGateway();

        address asset = ISecuritizeRedemptionGateway(securitizeRedemptionGateway).stableCoinToken();

        address dsToken = ISecuritizeRedemptionGateway(securitizeRedemptionGateway).dsToken();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);

        withdrawableAssets[0] = WithdrawableAsset(dsToken, token, asset, 90 days);

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address securitizeRedemptionGateway = SecuritizeRedemptionPhantomToken(token).redemptionGateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](1);
        claimableWithdrawals[0] = _getClaimableWithdrawal(creditAccount, token, securitizeRedemptionGateway);

        if (claimableWithdrawals[0].outputs.length == 0 || claimableWithdrawals[0].outputs[0].amount == 0) {
            claimableWithdrawals = new ClaimableWithdrawal[](0);
        }

        PendingWithdrawal[] memory pendingWithdrawals =
            _getPendingWithdrawals(creditAccount, securitizeRedemptionGateway);

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
            abi.encodeCall(ISecuritizeRedemptionGatewayAdapter.redeem, (amount))
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
                pendingWithdrawals[redeemerCount].token = dsToken;
                pendingWithdrawals[redeemerCount].expectedOutputs = new WithdrawalOutput[](1);

                uint256 redemptionValue = SecuritizeRedeemer(redeemers[i]).getCurrentRedemptionValue();
                pendingWithdrawals[redeemerCount].expectedOutputs[0] =
                    WithdrawalOutput(stableCoinToken, false, redemptionValue);

                uint256 startingTimestamp = SecuritizeRedeemer(redeemers[i]).startingTimestamp();
                pendingWithdrawals[redeemerCount].claimableAt =
                    block.timestamp > startingTimestamp + 90 days ? block.timestamp : startingTimestamp + 90 days;
                redeemerCount++;
            }
        }

        return pendingWithdrawals;
    }

    function _getClaimableWithdrawal(address creditAccount, address withdrawalToken, address redemptionGateway)
        internal
        view
        returns (ClaimableWithdrawal memory withdrawal)
    {
        address stableCoinToken = ISecuritizeRedemptionGateway(redemptionGateway).stableCoinToken();
        address dsToken = ISecuritizeRedemptionGateway(redemptionGateway).dsToken();

        withdrawal.token = dsToken;
        withdrawal.withdrawalPhantomToken = withdrawalToken;
        withdrawal.outputs = new WithdrawalOutput[](1);
        withdrawal.outputs[0] = WithdrawalOutput(stableCoinToken, false, 0);

        address[] memory redeemers = ISecuritizeRedemptionGateway(redemptionGateway).getRedeemers(creditAccount);

        uint256 redeemerCount = 0;

        for (uint256 i = 0; i < redeemers.length; i++) {
            if (
                _isRedeemerClaimable(redeemers[i], stableCoinToken)
                    || SecuritizeRedeemer(redeemers[i]).pendingDsTokenAmount() == 0
            ) redeemerCount++;
        }

        address[] memory claimableRedeemers = new address[](redeemerCount);

        redeemerCount = 0;

        for (uint256 i = 0; i < redeemers.length; i++) {
            if (
                _isRedeemerClaimable(redeemers[i], stableCoinToken)
                    || SecuritizeRedeemer(redeemers[i]).pendingDsTokenAmount() == 0
            ) {
                withdrawal.outputs[0].amount += IERC20(stableCoinToken).balanceOf(redeemers[i]);
                withdrawal.withdrawalTokenSpent += SecuritizeRedeemer(redeemers[i]).getRedemptionAmount();
                claimableRedeemers[redeemerCount] = redeemers[i];
                redeemerCount++;
            }
        }

        address securitizeRedemptionGatewayAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(redemptionGateway);

        withdrawal.claimCalls = new MultiCall[](claimableRedeemers.length);
        withdrawal.claimCalls[0] = MultiCall(
            securitizeRedemptionGatewayAdapter, abi.encodeCall(ISecuritizeRedemptionGateway.claim, (claimableRedeemers))
        );

        return withdrawal;
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
