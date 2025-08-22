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

import {UpshiftVaultWithdrawalPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/upshift/UpshiftVaultWithdrawalPhantomToken.sol";

import {UpshiftVaultGateway} from "@gearbox-protocol/integrations-v3/contracts/helpers/upshift/UpshiftVaultGateway.sol";
import {IUpshiftVaultGateway} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/upshift/IUpshiftVaultGateway.sol";

import {IUpshiftVault} from "@gearbox-protocol/integrations-v3/contracts/integrations/upshift/IUpshiftVault.sol";
import {IUpshiftVaultAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/upshift/IUpshiftVaultAdapter.sol";
import {PendingRedeem} from "@gearbox-protocol/integrations-v3/contracts/helpers/upshift/UpshiftVaultGateway.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

contract UpshiftWithdrawalSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "GLOBAL::UPSHIFT_WD_SC";

    uint256 internal constant EPOCH = 1 weeks;
    uint256 internal constant EPOCH_OFFSET = 3 days;

    function getWithdrawableAssets(address, address token)
        external
        view
        returns (WithdrawableAsset[] memory)
    {
        address vault = UpshiftVaultWithdrawalPhantomToken(token).vault();

        address asset = IERC4626(vault).asset();

        (,,, uint256 claimableTimestamp) = IUpshiftVault(vault).getWithdrawalEpoch();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);

        withdrawableAssets[0] = WithdrawableAsset(
            vault, token, asset, claimableTimestamp > block.timestamp ? claimableTimestamp - block.timestamp : 0
        );

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address upshiftVaultGateway = UpshiftVaultWithdrawalPhantomToken(token).gateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](1);
        claimableWithdrawals[0] = _getClaimableWithdrawal(creditAccount, upshiftVaultGateway);

        if (claimableWithdrawals[0].outputs.length == 0 || claimableWithdrawals[0].outputs[0].amount == 0) {
            claimableWithdrawals = new ClaimableWithdrawal[](0);
        }

        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(creditAccount, upshiftVaultGateway);

        return (claimableWithdrawals, pendingWithdrawals);
    }

    function getWithdrawalRequestResult(address creditAccount, address token, address withdrawalToken, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory requestableWithdrawal)
    {
        address upshiftVaultGateway = UpshiftVaultWithdrawalPhantomToken(withdrawalToken).gateway();

        address upshiftVaultGatewayAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(upshiftVaultGateway);

        (,,, uint256 claimableTimestamp) =
            IUpshiftVault(UpshiftVaultWithdrawalPhantomToken(token).vault()).getWithdrawalEpoch();

        address vault = UpshiftVaultWithdrawalPhantomToken(token).vault();
        address asset = IERC4626(vault).asset();

        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;
        requestableWithdrawal.outputs = new WithdrawalOutput[](1);

        if (claimableTimestamp < block.timestamp) {
            requestableWithdrawal.outputs[0] = WithdrawalOutput(asset, false, IERC4626(vault).previewRedeem(amount));
            requestableWithdrawal.requestCalls = new MultiCall[](2);

            requestableWithdrawal.requestCalls[0] = MultiCall(
                address(upshiftVaultGatewayAdapter), abi.encodeCall(IUpshiftVaultAdapter.requestRedeem, (amount))
            );

            requestableWithdrawal.requestCalls[1] = MultiCall(
                address(upshiftVaultGatewayAdapter),
                abi.encodeCall(IUpshiftVaultAdapter.claim, (IERC4626(vault).previewRedeem(amount)))
            );

            requestableWithdrawal.claimableAt = block.timestamp;
        } else {
            requestableWithdrawal.outputs[0] =
                WithdrawalOutput(withdrawalToken, true, IERC4626(vault).previewRedeem(amount));

            requestableWithdrawal.requestCalls = new MultiCall[](1);

            requestableWithdrawal.requestCalls[0] = MultiCall(
                address(upshiftVaultGatewayAdapter), abi.encodeCall(IUpshiftVaultAdapter.requestRedeem, (amount))
            );
            requestableWithdrawal.claimableAt = claimableTimestamp;
        }

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address creditAccount, address upshiftVaultGateway)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address vault = IUpshiftVaultGateway(upshiftVaultGateway).upshiftVault();

        address asset = IERC4626(vault).asset();

        (uint256 claimableTimestamp, uint256 assets,,,) =
            UpshiftVaultGateway(upshiftVaultGateway).pendingRedeems(creditAccount);

        if (block.timestamp < claimableTimestamp) {
            pendingWithdrawals = new PendingWithdrawal[](1);
            pendingWithdrawals[0].token = vault;
            pendingWithdrawals[0].expectedOutputs = new WithdrawalOutput[](1);
            pendingWithdrawals[0].expectedOutputs[0] = WithdrawalOutput(asset, false, assets);
            pendingWithdrawals[0].claimableAt = claimableTimestamp;
        } else {
            pendingWithdrawals = new PendingWithdrawal[](0);
        }

        return pendingWithdrawals;
    }

    function _getClaimableWithdrawal(address creditAccount, address upshiftVaultGateway)
        internal
        view
        returns (ClaimableWithdrawal memory withdrawal)
    {
        address vault = IUpshiftVaultGateway(upshiftVaultGateway).upshiftVault();

        address asset = IERC4626(vault).asset();

        address upshiftVaultGatewayAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(upshiftVaultGateway);

        (uint256 claimableTimestamp, uint256 assets,,,) =
            UpshiftVaultGateway(upshiftVaultGateway).pendingRedeems(creditAccount);

        if (block.timestamp >= claimableTimestamp) {
            withdrawal.token = vault;
            withdrawal.outputs = new WithdrawalOutput[](1);
            withdrawal.outputs[0] = WithdrawalOutput(asset, false, assets);
            withdrawal.claimCalls = new MultiCall[](1);
            withdrawal.claimCalls[0] =
                MultiCall(address(upshiftVaultGatewayAdapter), abi.encodeCall(IUpshiftVaultAdapter.claim, (assets)));
        }

        return withdrawal;
    }
}
