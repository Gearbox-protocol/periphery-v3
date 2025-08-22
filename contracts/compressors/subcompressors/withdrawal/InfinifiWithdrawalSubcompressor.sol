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

import {InfinifiUnwindingGateway} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/infinifi/InfinifiUnwindingGateway.sol";
import {InfinifiUnwindingPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/infinifi/InfinifiUnwindingPhantomToken.sol";

import {
    IInfinifiLockingController,
    IInfinifiUnwindingModule,
    UnwindingPosition
} from "@gearbox-protocol/integrations-v3/contracts/integrations/infinifi/IInfinifiGateway.sol";
import {
    IInfinifiUnwindingGateway,
    UserUnwindingData
} from "@gearbox-protocol/integrations-v3/contracts/interfaces/infinifi/IInfinifiUnwindingGateway.sol";
import {IInfinifiGatewayAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/infinifi/IInfinifiGatewayAdapter.sol";
import {IInfinifiUnwindingGatewayAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/infinifi/IInfinifiUnwindingGatewayAdapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

contract InfinifiWithdrawalSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "GLOBAL::INFINIFI_WD_SC";

    uint256 internal constant EPOCH = 1 weeks;
    uint256 internal constant EPOCH_OFFSET = 3 days;

    function getWithdrawableAssets(address creditManager, address token)
        external
        view
        returns (WithdrawableAsset[] memory)
    {
        address infinifiUnwindingGateway = InfinifiUnwindingPhantomToken(token).infinifiUnwindingGateway();

        address asset = IInfinifiUnwindingGateway(infinifiUnwindingGateway).iUSD();

        address unwindingGatewayAdapter = ICreditManagerV3(creditManager).contractToAdapter(infinifiUnwindingGateway);

        address[] memory lockedTokens =
            IInfinifiUnwindingGatewayAdapter(unwindingGatewayAdapter).getAllowedLockedTokens();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](lockedTokens.length);

        for (uint256 i = 0; i < lockedTokens.length; i++) {
            uint32 unwindingEpochs =
                IInfinifiGatewayAdapter(unwindingGatewayAdapter).lockedTokenToUnwindingEpoch(lockedTokens[i]);
            withdrawableAssets[i] = WithdrawableAsset(
                lockedTokens[i], token, asset, _getClaimableAtFromCurrent(unwindingEpochs) - block.timestamp
            );
        }

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address infinifiUnwindingGateway = InfinifiUnwindingPhantomToken(token).infinifiUnwindingGateway();

        ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](1);
        claimableWithdrawals[0] = _getClaimableWithdrawal(creditAccount, token, infinifiUnwindingGateway);

        if (claimableWithdrawals[0].outputs.length == 0 || claimableWithdrawals[0].outputs[0].amount == 0) {
            claimableWithdrawals = new ClaimableWithdrawal[](0);
        }

        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(creditAccount, infinifiUnwindingGateway);

        return (claimableWithdrawals, pendingWithdrawals);
    }

    function getWithdrawalRequestResult(address creditAccount, address token, address withdrawalToken, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory requestableWithdrawal)
    {
        address infinifiUnwindingGateway = InfinifiUnwindingPhantomToken(withdrawalToken).infinifiUnwindingGateway();

        address unwindingGatewayAdapter = ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager())
            .contractToAdapter(infinifiUnwindingGateway);

        uint32 unwindingEpochs = IInfinifiGatewayAdapter(unwindingGatewayAdapter).lockedTokenToUnwindingEpoch(token);

        if (unwindingEpochs == 0) {
            return requestableWithdrawal;
        }

        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;
        requestableWithdrawal.outputs = new WithdrawalOutput[](1);
        requestableWithdrawal.requestCalls = new MultiCall[](1);
        requestableWithdrawal.claimableAt = _getClaimableAtFromCurrent(unwindingEpochs);

        requestableWithdrawal.requestCalls[0] = MultiCall(
            address(unwindingGatewayAdapter),
            abi.encodeCall(IInfinifiUnwindingGatewayAdapter.startUnwinding, (amount, unwindingEpochs))
        );

        requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, 0);

        address lockingController = IInfinifiUnwindingGateway(infinifiUnwindingGateway).lockingController();

        uint256 exchangeRate = IInfinifiLockingController(lockingController).exchangeRate(unwindingEpochs);

        requestableWithdrawal.outputs[0].amount = amount * exchangeRate / WAD;

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address creditAccount, address unwindingGateway)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address asset = IInfinifiUnwindingGateway(unwindingGateway).iUSD();

        UserUnwindingData memory userUnwindingData =
            IInfinifiUnwindingGateway(unwindingGateway).getUserUnwindingData(creditAccount);

        if (userUnwindingData.unwindingTimestamp == 0) {
            return pendingWithdrawals;
        }

        if (
            block.timestamp
                < _getClaimableAtFromUnwindingPosition(unwindingGateway, userUnwindingData.unwindingTimestamp)
        ) {
            pendingWithdrawals = new PendingWithdrawal[](1);
            pendingWithdrawals[0].token = IInfinifiLockingController(
                IInfinifiUnwindingGateway(unwindingGateway).lockingController()
            ).shareToken(userUnwindingData.unwindingEpochs);
            pendingWithdrawals[0].expectedOutputs = new WithdrawalOutput[](1);
            pendingWithdrawals[0].expectedOutputs[0] = WithdrawalOutput(
                asset, false, InfinifiUnwindingGateway(unwindingGateway).getPendingAssets(creditAccount)
            );
            pendingWithdrawals[0].claimableAt =
                _getClaimableAtFromUnwindingPosition(unwindingGateway, userUnwindingData.unwindingTimestamp);
        }

        return pendingWithdrawals;
    }

    function _getClaimableWithdrawal(address creditAccount, address, address unwindingGateway)
        internal
        view
        returns (ClaimableWithdrawal memory withdrawal)
    {
        address asset = IInfinifiUnwindingGateway(unwindingGateway).iUSD();

        UserUnwindingData memory userUnwindingData =
            IInfinifiUnwindingGateway(unwindingGateway).getUserUnwindingData(creditAccount);

        if (userUnwindingData.unwindingTimestamp == 0) {
            return withdrawal;
        }

        withdrawal.token = IInfinifiLockingController(IInfinifiUnwindingGateway(unwindingGateway).lockingController())
            .shareToken(userUnwindingData.unwindingEpochs);
        withdrawal.outputs = new WithdrawalOutput[](1);
        withdrawal.outputs[0] = WithdrawalOutput(asset, false, 0);

        if (userUnwindingData.isWithdrawn) {
            withdrawal.outputs[0].amount = userUnwindingData.unclaimedAssets;
        } else {
            uint256 pendingAssets = InfinifiUnwindingGateway(unwindingGateway).getPendingAssets(creditAccount);

            if (
                block.timestamp
                    < _getClaimableAtFromUnwindingPosition(unwindingGateway, userUnwindingData.unwindingTimestamp)
                    || pendingAssets == 0
            ) {
                return withdrawal;
            }

            withdrawal.outputs[0].amount = pendingAssets;
        }

        withdrawal.claimCalls = new MultiCall[](1);

        address unwindingGatewayAdapter =
            ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(unwindingGateway);

        withdrawal.claimCalls = new MultiCall[](1);

        withdrawal.claimCalls[0] = MultiCall(
            address(unwindingGatewayAdapter),
            abi.encodeCall(IInfinifiUnwindingGatewayAdapter.withdraw, (withdrawal.outputs[0].amount))
        );

        return withdrawal;
    }

    function _getClaimableAtFromUnwindingPosition(address unwindingGateway, uint256 unwindingTimestamp)
        internal
        view
        returns (uint256)
    {
        address unwindingModule = IInfinifiUnwindingGateway(unwindingGateway).unwindingModule();
        UnwindingPosition memory position =
            IInfinifiUnwindingModule(unwindingModule).positions(_unwindingId(unwindingGateway, unwindingTimestamp));

        uint32 claimableEpoch = position.toEpoch;

        return _timestampFromEpoch(claimableEpoch);
    }

    function _getClaimableAtFromCurrent(uint32 unwindingEpochs) internal view returns (uint256) {
        uint32 currentEpoch = _epochFromTimestamp(block.timestamp);
        return _timestampFromEpoch(unwindingEpochs + currentEpoch + 1);
    }

    function _epochFromTimestamp(uint256 timestamp) internal pure returns (uint32) {
        return uint32((timestamp - EPOCH_OFFSET) / EPOCH);
    }

    function _timestampFromEpoch(uint32 epoch) internal pure returns (uint256) {
        return uint256(epoch) * EPOCH + EPOCH_OFFSET;
    }

    function _unwindingId(address unwindingGateway, uint256 unwindingTimestamp) internal pure returns (bytes32) {
        return keccak256(abi.encode(unwindingGateway, unwindingTimestamp));
    }
}
