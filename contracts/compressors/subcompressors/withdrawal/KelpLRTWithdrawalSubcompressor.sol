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

import {IKelpLRTWithdrawalManagerGateway} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/kelp/IKelpLRTWithdrawalManagerGateway.sol";
import {IKelpLRTWithdrawalManagerAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/kelp/IKelpLRTWithdrawalManagerAdapter.sol";
import {IKelpLRTWithdrawalManager} from
    "@gearbox-protocol/integrations-v3/contracts/integrations/kelp/IKelpLRTWithdrawalManager.sol";

import {KelpLRTWithdrawalPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/kelp/KelpLRTWithdrawalPhantomToken.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

interface IKelpGatewayExt {
    function weth() external view returns (address);
}

contract KelpLRTWithdrawalSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "GLOBAL::KELP_LRT_WD_SC";

    function getWithdrawableAssets(address, address token) external view returns (WithdrawableAsset[] memory) {
        address withdrawalManagerGateway = KelpLRTWithdrawalPhantomToken(token).withdrawalManagerGateway();
        address asset = KelpLRTWithdrawalPhantomToken(token).tokenOut();
        address rsETH = IKelpLRTWithdrawalManagerGateway(withdrawalManagerGateway).rsETH();
        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);
        withdrawableAssets[0] = WithdrawableAsset(rsETH, token, asset, 21 days);
        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address withdrawalManagerGateway = KelpLRTWithdrawalPhantomToken(token).withdrawalManagerGateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](1);
        claimableWithdrawals[0] = _getClaimableWithdrawal(creditAccount, token, withdrawalManagerGateway);

        if (claimableWithdrawals[0].outputs.length == 0 || claimableWithdrawals[0].outputs[0].amount == 0) {
            claimableWithdrawals = new ClaimableWithdrawal[](0);
        }

        PendingWithdrawal[] memory pendingWithdrawals =
            _getPendingWithdrawals(creditAccount, token, withdrawalManagerGateway);

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
        address withdrawalManagerGateway = KelpLRTWithdrawalPhantomToken(withdrawalToken).withdrawalManagerGateway();

        address withdrawalManagerAdapter = ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager())
            .contractToAdapter(withdrawalManagerGateway);

        address asset = KelpLRTWithdrawalPhantomToken(withdrawalToken).tokenOut();

        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;
        requestableWithdrawal.outputs = new WithdrawalOutput[](1);
        requestableWithdrawal.requestCalls = new MultiCall[](1);
        requestableWithdrawal.claimableAt = block.timestamp + 21 days;

        requestableWithdrawal.requestCalls[0] = MultiCall(
            address(withdrawalManagerAdapter),
            abi.encodeCall(IKelpLRTWithdrawalManagerAdapter.initiateWithdrawal, (asset, amount, ""))
        );

        requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, 0);

        address withdrawalManager = IKelpLRTWithdrawalManagerGateway(withdrawalManagerGateway).withdrawalManager();
        address weth = IKelpGatewayExt(withdrawalManagerGateway).weth();

        requestableWithdrawal.outputs[0].amount =
            IKelpLRTWithdrawalManager(withdrawalManager).getExpectedAssetAmount(_assetOrETH(asset, weth), amount);

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address creditAccount, address withdrawalToken, address withdrawalManagerGateway)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address withdrawalManager = IKelpLRTWithdrawalManagerGateway(withdrawalManagerGateway).withdrawalManager();
        address rsETH = IKelpLRTWithdrawalManagerGateway(withdrawalManagerGateway).rsETH();

        address withdrawer =
            IKelpLRTWithdrawalManagerGateway(withdrawalManagerGateway).accountToWithdrawer(creditAccount);
        address weth = IKelpGatewayExt(withdrawalManagerGateway).weth();
        address asset = KelpLRTWithdrawalPhantomToken(withdrawalToken).tokenOut();

        uint256 numRequests = _getNumRequests(_assetOrETH(asset, weth), withdrawalManager, withdrawer);
        uint256 nextLockedNonce = IKelpLRTWithdrawalManager(withdrawalManager).nextLockedNonce(_assetOrETH(asset, weth));

        pendingWithdrawals = new PendingWithdrawal[](numRequests);

        for (uint256 i = 0; i < numRequests; i++) {
            (, uint256 expectedAssetAmount, uint256 withdrawalStartBlock, uint256 userNonce) =
                IKelpLRTWithdrawalManager(withdrawalManager).getUserWithdrawalRequest(_assetOrETH(asset, weth), withdrawer, i);

            if (userNonce >= nextLockedNonce) {
                pendingWithdrawals[i].token = rsETH;
                pendingWithdrawals[i].expectedOutputs = new WithdrawalOutput[](1);
                pendingWithdrawals[i].expectedOutputs[0] = WithdrawalOutput(asset, false, expectedAssetAmount);
                uint256 elapsedTime = 12 * (block.number - withdrawalStartBlock);
                pendingWithdrawals[i].claimableAt =
                    block.timestamp + (21 days > elapsedTime ? 21 days - elapsedTime : 0);
            }
        }

        return pendingWithdrawals;
    }

    function _getNumRequests(address asset, address withdrawalManager, address withdrawer)
        internal
        view
        returns (uint256)
    {
        (uint128 start, uint128 end) =
            IKelpLRTWithdrawalManager(withdrawalManager).userAssociatedNonces(asset, withdrawer);
        return uint256(end - start);
    }

    function _getClaimableWithdrawal(address creditAccount, address withdrawalToken, address withdrawalManagerGateway)
        internal
        view
        returns (ClaimableWithdrawal memory withdrawal)
    {
        address rsETH = IKelpLRTWithdrawalManagerGateway(withdrawalManagerGateway).rsETH();
        address asset = KelpLRTWithdrawalPhantomToken(withdrawalToken).tokenOut();

        withdrawal.token = rsETH;
        uint256 claimable =
            IKelpLRTWithdrawalManagerGateway(withdrawalManagerGateway).getClaimableAssetAmount(creditAccount, asset);

        if (claimable > 0) {
            withdrawal.outputs = new WithdrawalOutput[](1);
            withdrawal.outputs[0] = WithdrawalOutput(asset, false, claimable);
            withdrawal.withdrawalPhantomToken = withdrawalToken;
            withdrawal.withdrawalTokenSpent = claimable;

            address withdrawalManagerAdapter = ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager())
                .contractToAdapter(withdrawalManagerGateway);

            withdrawal.claimCalls = new MultiCall[](1);
            withdrawal.claimCalls[0] = MultiCall(
                address(withdrawalManagerAdapter),
                abi.encodeCall(IKelpLRTWithdrawalManagerAdapter.completeWithdrawal, (asset, claimable, ""))
            );
        }

        return withdrawal;
    }

    function _assetOrETH(address asset, address weth) internal pure returns (address) {
        return asset == weth ? ETH : asset;
    }
}
