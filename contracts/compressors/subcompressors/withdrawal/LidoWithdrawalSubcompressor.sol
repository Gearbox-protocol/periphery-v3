// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2025.
pragma solidity ^0.8.23;

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

import {LidoWithdrawalPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/lido/LidoWithdrawalPhantomToken.sol";

import {ILidoWithdrawalQueueGateway} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/lido/ILidoWithdrawalQueueGateway.sol";
import {ILidoWithdrawalQueueAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/lido/ILidoWithdrawalQueueAdapter.sol";
import {
    ILidoWithdrawalQueue,
    WithdrawalRequestStatus
} from "@gearbox-protocol/integrations-v3/contracts/integrations/lido/ILidoWithdrawalQueue.sol";
import {IwstETH} from "@gearbox-protocol/integrations-v3/contracts/integrations/lido/IWstETH.sol";
import {IstETHGetters} from "@gearbox-protocol/integrations-v3/contracts/integrations/lido/IstETH.sol";

import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

contract LidoWithdrawalSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "GLOBAL::LIDO_WD_SC";

    uint256 public constant APPROX_STETH_PER_DAY = 9000 * WAD;

    uint256 public constant MAX_STETH_PER_REQUEST = 1000 * WAD;
    uint256 public constant MAX_STETH_PER_WSTETH_REQUEST = 999 * WAD;

    function getWithdrawableAssets(address, address token) external view returns (WithdrawableAsset[] memory) {
        address withdrawalQueueGateway = LidoWithdrawalPhantomToken(token).withdrawalQueueGateway();

        address weth = ILidoWithdrawalQueueGateway(withdrawalQueueGateway).weth();
        address steth = ILidoWithdrawalQueueGateway(withdrawalQueueGateway).steth();
        address wsteth = ILidoWithdrawalQueueGateway(withdrawalQueueGateway).wsteth();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](2);

        withdrawableAssets[0] = WithdrawableAsset(
            steth, token, weth, _getWithdrawalTimeFromStETH(ILidoWithdrawalQueue(steth).unfinalizedStETH())
        );

        withdrawableAssets[1] = WithdrawableAsset(
            wsteth, token, weth, _getWithdrawalTimeFromStETH(ILidoWithdrawalQueue(wsteth).unfinalizedStETH())
        );

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address withdrawalQueueGateway = LidoWithdrawalPhantomToken(token).withdrawalQueueGateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](1);
        claimableWithdrawals[0] = _getClaimableWithdrawal(creditAccount, withdrawalQueueGateway);

        if (claimableWithdrawals[0].outputs.length == 0 || claimableWithdrawals[0].outputs[0].amount == 0) {
            claimableWithdrawals = new ClaimableWithdrawal[](0);
        }

        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(creditAccount, withdrawalQueueGateway);

        return (claimableWithdrawals, pendingWithdrawals);
    }

    function getWithdrawalRequestResult(address creditAccount, address token, address withdrawalToken, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory requestableWithdrawal)
    {
        address withdrawalQueueGateway = LidoWithdrawalPhantomToken(withdrawalToken).withdrawalQueueGateway();

        address withdrawalQueueGatewayAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(withdrawalQueueGateway);

        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;
        requestableWithdrawal.outputs = new WithdrawalOutput[](1);

        if (token == ILidoWithdrawalQueueGateway(withdrawalQueueGateway).steth()) {
            requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, amount);
            uint256[] memory amounts;

            {
                uint256 nRequests = (amount - 1) / MAX_STETH_PER_REQUEST + 1;
                amounts = new uint256[](nRequests);
                uint256 totalAmount = amount;

                for (uint256 i = 0; i < nRequests; i++) {
                    if (totalAmount > MAX_STETH_PER_REQUEST) {
                        amounts[i] = MAX_STETH_PER_REQUEST;
                        totalAmount -= MAX_STETH_PER_REQUEST;
                    } else {
                        amounts[i] = totalAmount;
                        totalAmount = 0;
                    }
                }
            }

            requestableWithdrawal.requestCalls = new MultiCall[](1);

            requestableWithdrawal.requestCalls[0] = MultiCall(
                address(withdrawalQueueGatewayAdapter),
                abi.encodeCall(ILidoWithdrawalQueueAdapter.requestWithdrawals, (amounts))
            );

            requestableWithdrawal.claimableAt = _getClaimableTimeFromStETH(
                ILidoWithdrawalQueue(ILidoWithdrawalQueueGateway(withdrawalQueueGateway).withdrawalQueue())
                    .unfinalizedStETH() + amount
            );
        } else if (token == ILidoWithdrawalQueueGateway(withdrawalQueueGateway).wsteth()) {
            address wsteth = ILidoWithdrawalQueueGateway(withdrawalQueueGateway).wsteth();
            uint256 stethAmount = IwstETH(wsteth).getStETHByWstETH(amount);
            requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, stethAmount);
            uint256[] memory amounts;

            {
                uint256 nRequests = (stethAmount - 1) / MAX_STETH_PER_WSTETH_REQUEST + 1;
                amounts = new uint256[](nRequests);
                uint256 totalAmount = amount;
                uint256 maxWstETH = IwstETH(wsteth).getWstETHByStETH(MAX_STETH_PER_WSTETH_REQUEST);

                for (uint256 i = 0; i < nRequests; i++) {
                    if (totalAmount > maxWstETH) {
                        amounts[i] = maxWstETH;
                        totalAmount -= maxWstETH;
                    } else {
                        amounts[i] = totalAmount;
                        totalAmount = 0;
                    }
                }
            }

            requestableWithdrawal.requestCalls[0] = MultiCall(
                address(withdrawalQueueGatewayAdapter),
                abi.encodeCall(ILidoWithdrawalQueueAdapter.requestWithdrawalsWstETH, (amounts))
            );

            requestableWithdrawal.claimableAt = _getClaimableTimeFromStETH(
                ILidoWithdrawalQueue(ILidoWithdrawalQueueGateway(withdrawalQueueGateway).withdrawalQueue())
                    .unfinalizedStETH() + stethAmount
            );
        }

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address creditAccount, address withdrawalQueueGateway)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address withdrawalQueue = ILidoWithdrawalQueueGateway(withdrawalQueueGateway).withdrawalQueue();
        address steth = ILidoWithdrawalQueueGateway(withdrawalQueueGateway).steth();

        uint256[] memory requestIds = ILidoWithdrawalQueueGateway(withdrawalQueueGateway).getRequestIds(creditAccount);

        uint256 stethBefore = _getUnfinalizedStETHBeforeRequest(withdrawalQueue, requestIds[0]);

        WithdrawalRequestStatus[] memory statuses =
            ILidoWithdrawalQueue(withdrawalQueue).getWithdrawalStatus(requestIds);

        for (uint256 i = 0; i < statuses.length; i++) {
            if (!statuses[i].isFinalized) {
                PendingWithdrawal memory pendingWithdrawal;
                pendingWithdrawal.token = steth;
                pendingWithdrawal.expectedOutputs = new WithdrawalOutput[](1);

                pendingWithdrawal.expectedOutputs[0] = WithdrawalOutput(
                    ILidoWithdrawalQueueGateway(withdrawalQueueGateway).weth(),
                    false,
                    _getExpectedWETH(statuses[i], steth)
                );
                pendingWithdrawal.claimableAt = _getClaimableTimeFromStETH(stethBefore + statuses[i].amountOfStETH);
                pendingWithdrawals = pendingWithdrawals.push(pendingWithdrawal);
                stethBefore += statuses[i].amountOfStETH;
            }
        }

        return pendingWithdrawals;
    }

    function _getClaimableWithdrawal(address creditAccount, address withdrawalQueueGateway)
        internal
        view
        returns (ClaimableWithdrawal memory withdrawal)
    {
        address steth = ILidoWithdrawalQueueGateway(withdrawalQueueGateway).steth();

        address withdrawalQueueAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(withdrawalQueueGateway);

        uint256 claimableWETH = ILidoWithdrawalQueueGateway(withdrawalQueueGateway).getClaimableWETH(creditAccount);

        if (claimableWETH > 0) {
            withdrawal.token = steth;
            withdrawal.outputs = new WithdrawalOutput[](1);
            withdrawal.outputs[0] =
                WithdrawalOutput(ILidoWithdrawalQueueGateway(withdrawalQueueGateway).weth(), false, claimableWETH);
            withdrawal.claimCalls = new MultiCall[](1);
            withdrawal.claimCalls[0] = MultiCall(
                address(withdrawalQueueAdapter),
                abi.encodeCall(ILidoWithdrawalQueueAdapter.claimWithdrawals, (claimableWETH))
            );
        }

        return withdrawal;
    }

    function _getExpectedWETH(WithdrawalRequestStatus memory status, address steth) internal view returns (uint256) {
        uint256 totalShares = IstETHGetters(steth).getTotalShares();
        uint256 totalPooledEther = IstETHGetters(steth).getTotalPooledEther();
        uint256 amountByShares = status.amountOfShares * totalPooledEther / totalShares;
        return amountByShares < status.amountOfStETH ? amountByShares : status.amountOfStETH;
    }

    function _getUnfinalizedStETHBeforeRequest(address withdrawalQueue, uint256 requestId)
        internal
        view
        returns (uint256)
    {
        uint256 currentId = ILidoWithdrawalQueue(withdrawalQueue).getLastFinalizedRequestId() + 1;

        uint256 stethAmount = 0;

        while (currentId < requestId) {
            uint256[] memory requestIds = new uint256[](1);
            requestIds[0] = currentId;
            WithdrawalRequestStatus[] memory statuses =
                ILidoWithdrawalQueue(withdrawalQueue).getWithdrawalStatus(requestIds);
            stethAmount += statuses[0].amountOfStETH;
            currentId++;
        }

        return stethAmount;
    }

    function _getClaimableTimeFromStETH(uint256 amount) internal view returns (uint256) {
        uint256 epochDays = (block.timestamp / 1 days * 1 days);
        return epochDays + _getWithdrawalTimeFromStETH(amount);
    }

    function _getWithdrawalTimeFromStETH(uint256 amount) internal pure returns (uint256) {
        uint256 daysUntilFinalized = amount / APPROX_STETH_PER_DAY + 1;

        return daysUntilFinalized * 1 days;
    }
}
