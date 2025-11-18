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

import {IMellowDepositQueueAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/mellow/IMellowDepositQueueAdapter.sol";
import {IMellowDepositQueue} from
    "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowDepositQueue.sol";
import {IMellowFlexibleDepositGateway} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/mellow/IMellowFlexibleDepositGateway.sol";
import {MellowFlexibleDepositPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/mellow/MellowFlexibleDepositPhantomToken.sol";
import {IMellowFlexibleVault} from
    "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowFlexibleVault.sol";
import {IMellowRateOracle} from "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowRateOracle.sol";

import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

contract MellowFlexibleDepositSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "GLOBAL::MELF_DEPOSIT_WD_SC";

    function getWithdrawableAssets(address, address token) external view returns (WithdrawableAsset[] memory) {
        address depositQueueGateway = MellowFlexibleDepositPhantomToken(token).depositQueueGateway();
        address asset = IMellowFlexibleDepositGateway(depositQueueGateway).vaultToken();
        address depositedAsset = IMellowFlexibleDepositGateway(depositQueueGateway).asset();
        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);
        withdrawableAssets[0] =
            WithdrawableAsset(depositedAsset, token, asset, _getDepositInterval(depositQueueGateway));
        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address depositQueueGateway = MellowFlexibleDepositPhantomToken(token).depositQueueGateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](1);
        claimableWithdrawals[0] = _getClaimableWithdrawal(creditAccount, token, depositQueueGateway);

        if (claimableWithdrawals[0].outputs.length == 0 || claimableWithdrawals[0].outputs[0].amount == 0) {
            claimableWithdrawals = new ClaimableWithdrawal[](0);
        }

        PendingWithdrawal[] memory pendingWithdrawals =
            _getPendingWithdrawals(creditAccount, token, depositQueueGateway);

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
        address depositQueueGateway = MellowFlexibleDepositPhantomToken(withdrawalToken).depositQueueGateway();

        address depositQueueAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(depositQueueGateway);

        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;
        requestableWithdrawal.outputs = new WithdrawalOutput[](1);
        requestableWithdrawal.requestCalls = new MultiCall[](1);
        requestableWithdrawal.claimableAt = block.timestamp + _getDepositInterval(depositQueueGateway);

        requestableWithdrawal.requestCalls[0] = MultiCall(
            address(depositQueueAdapter),
            abi.encodeCall(IMellowDepositQueueAdapter.deposit, (amount, address(0), new bytes32[](0)))
        );

        requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, 0);

        address mellowRateOracle = MellowFlexibleDepositPhantomToken(withdrawalToken).mellowRateOracle();

        uint256 assetPrice = WAD * WAD / IMellowRateOracle(mellowRateOracle).getRate();
        requestableWithdrawal.outputs[0].amount = amount * assetPrice / WAD;

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address creditAccount, address withdrawalToken, address depositQueueGateway)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address asset = IMellowFlexibleDepositGateway(depositQueueGateway).vaultToken();
        address depositedAsset = IMellowFlexibleDepositGateway(depositQueueGateway).asset();
        address depositor = IMellowFlexibleDepositGateway(depositQueueGateway).accountToDepositor(creditAccount);

        pendingWithdrawals = new PendingWithdrawal[](1);

        pendingWithdrawals[0].token = depositedAsset;
        pendingWithdrawals[0].expectedOutputs = new WithdrawalOutput[](1);
        pendingWithdrawals[0].expectedOutputs[0] = WithdrawalOutput(asset, false, 0);
        pendingWithdrawals[0].claimableAt = _getClaimableAt(depositor, depositQueueGateway);

        uint256 pendingAssets = IMellowFlexibleDepositGateway(depositQueueGateway).getPendingAssets(creditAccount);

        address mellowRateOracle = MellowFlexibleDepositPhantomToken(withdrawalToken).mellowRateOracle();
        uint256 assetPrice = WAD * WAD / IMellowRateOracle(mellowRateOracle).getRate();

        pendingWithdrawals[0].expectedOutputs[0].amount = pendingAssets * assetPrice / WAD;

        return pendingWithdrawals;
    }

    function _getClaimableWithdrawal(address creditAccount, address withdrawalToken, address depositQueueGateway)
        internal
        view
        returns (ClaimableWithdrawal memory withdrawal)
    {
        address asset = IMellowFlexibleDepositGateway(depositQueueGateway).vaultToken();
        address depositedAsset = IMellowFlexibleDepositGateway(depositQueueGateway).asset();

        withdrawal.token = depositedAsset;
        uint256 claimable = IMellowFlexibleDepositGateway(depositQueueGateway).getClaimableShares(creditAccount);

        if (claimable > 0) {
            withdrawal.outputs = new WithdrawalOutput[](1);
            withdrawal.outputs[0] = WithdrawalOutput(asset, false, claimable);
            withdrawal.withdrawalPhantomToken = withdrawalToken;
            withdrawal.withdrawalTokenSpent = claimable;

            address depositQueueAdapter =
                ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(depositQueueGateway);

            withdrawal.claimCalls = new MultiCall[](1);
            withdrawal.claimCalls[0] =
                MultiCall(address(depositQueueAdapter), abi.encodeCall(IMellowDepositQueueAdapter.claim, (claimable)));
        }

        return withdrawal;
    }

    function _getDepositInterval(address depositQueueGateway) internal view returns (uint256) {
        address depositQueue = IMellowFlexibleDepositGateway(depositQueueGateway).mellowDepositQueue();
        address vault = IMellowDepositQueue(depositQueue).vault();
        address oracle = IMellowFlexibleVault(vault).oracle();
        (,,,,, uint32 depositInterval,) = IMellowRateOracle(oracle).securityParams();
        return depositInterval + 1 days;
    }

    function _getClaimableAt(address depositor, address depositQueueGateway) internal view returns (uint256) {
        address depositQueue = IMellowFlexibleDepositGateway(depositQueueGateway).mellowDepositQueue();
        (uint256 startTimestamp,) = IMellowDepositQueue(depositQueue).requestOf(depositor);
        uint256 elapsedTime = block.timestamp - startTimestamp;
        uint256 depositInterval = _getDepositInterval(depositQueueGateway);
        return elapsedTime > depositInterval ? block.timestamp : block.timestamp + depositInterval - elapsedTime;
    }
}
