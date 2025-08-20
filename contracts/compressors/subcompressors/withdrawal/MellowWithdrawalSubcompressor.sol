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

import {MellowWithdrawalPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/mellow/MellowWithdrawalPhantomToken.sol";
import {
    IMellowMultiVault,
    IMellowWithdrawalQueue,
    IEigenLayerWithdrawalQueue,
    Subvault,
    MellowProtocol
} from "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowMultiVault.sol";
import {IMellowClaimerAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/mellow/IMellowClaimerAdapter.sol";
import {IMellow4626VaultAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/mellow/IMellow4626VaultAdapter.sol";
import {IERC4626Adapter} from "@gearbox-protocol/integrations-v3/contracts/interfaces/erc4626/IERC4626Adapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

struct EpochData {
    bool isClaimed;
    uint256 sharesToClaim;
    uint256 claimableAssets;
}

struct EigenLayerWithdrawal {
    address staker;
    address delegatedTo;
    address withdrawer;
    uint256 nonce;
    uint32 startBlock;
    address[] strategies;
    uint256[] scaledShares;
}

interface ISymbioticSubvault {
    function nextEpochStart() external view returns (uint256);
    function epochDuration() external view returns (uint256);
    function withdrawalsOf(uint256 epoch, address withdrawalQueue) external view returns (uint256);
}

interface IEigenLayerDelegation {
    function minWithdrawalDelayBlocks() external view returns (uint256);
}

interface IEigenLayerWithdrawalQueueExt is IEigenLayerWithdrawalQueue {
    function delegation() external view returns (address);

    function latestWithdrawableBlock() external view returns (uint256);

    function convertScaledSharesToShares(
        EigenLayerWithdrawal memory withdrawal,
        uint256 scaledShares,
        uint256 totalScaledShares
    ) external view returns (uint256);

    function getWithdrawalRequest(uint256 index, address account)
        external
        view
        returns (
            EigenLayerWithdrawal memory data,
            bool isClaimed,
            uint256 assets,
            uint256 shares,
            uint256 accountShares
        );

    function isolatedVault() external view returns (address);
    function strategy() external view returns (address);
}

interface IEigenLayerIsolatedVault {
    function sharesToUnderlyingView(address strategy, uint256 shares) external view returns (uint256);
}

interface ISymbioticWithdrawalQueue {
    function getCurrentEpoch() external view returns (uint256);
    function getAccountData(address account)
        external
        view
        returns (uint256 sharesToClaimPrev, uint256 sharesToClaim, uint256 claimableAssets, uint256 claimEpoch);
    function getEpochData(uint256 epoch) external view returns (EpochData memory);
}

interface IMellowMultiVaultExt is IMellowMultiVault {
    function withdrawalStrategy() external view returns (address);
}

struct MellowWithdrawalAmounts {
    uint256 subvaultIndex;
    uint256 claimable;
    uint256 pending;
    uint256 staked;
}

interface IMellowWithdrawalStrategy {
    function calculateWithdrawalAmounts(address multiVault, uint256 amount)
        external
        view
        returns (MellowWithdrawalAmounts[] memory amounts);
}

contract MellowWithdrawalSubcompressor is IWithdrawalSubcompressor {
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "GLOBAL::MELLOW_WD_SC";

    function getWithdrawableAssets(address, address token) external view returns (WithdrawableAsset[] memory) {
        address multiVault = MellowWithdrawalPhantomToken(token).multiVault();
        address asset = IERC4626(multiVault).asset();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);
        withdrawableAssets[0] = WithdrawableAsset(multiVault, token, asset, _getWithdrawalLength(multiVault));

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount, address token)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address multiVault = MellowWithdrawalPhantomToken(token).multiVault();

        ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](1);
        claimableWithdrawals[0] = _getClaimableWithdrawal(creditAccount, token, multiVault);

        if (claimableWithdrawals[0].outputs[0].amount == 0) {
            claimableWithdrawals = new ClaimableWithdrawal[](0);
        }

        PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(creditAccount, multiVault);

        return (claimableWithdrawals, pendingWithdrawals);
    }

    function getWithdrawalRequestResult(address creditAccount, address token, address withdrawalToken, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory requestableWithdrawal)
    {
        requestableWithdrawal.token = token;
        requestableWithdrawal.amountIn = amount;

        uint256 assets = IERC4626(token).convertToAssets(amount);

        address withdrawalStrategy = IMellowMultiVaultExt(token).withdrawalStrategy();

        MellowWithdrawalAmounts[] memory amounts =
            IMellowWithdrawalStrategy(withdrawalStrategy).calculateWithdrawalAmounts(token, assets);

        uint256 liquid = assets;

        for (uint256 i = 0; i < amounts.length; ++i) {
            Subvault memory subvault = IMellowMultiVault(token).subvaultAt(amounts[i].subvaultIndex);

            if (subvault.protocol == MellowProtocol.SYMBIOTIC) {
                liquid -= amounts[i].staked + amounts[i].pending;
            } else if (subvault.protocol == MellowProtocol.EIGEN_LAYER) {
                liquid -= amounts[i].staked + amounts[i].pending;
            }
        }

        if (liquid < assets) {
            requestableWithdrawal.outputs = new WithdrawalOutput[](2);
            requestableWithdrawal.outputs[0] = WithdrawalOutput(IERC4626(token).asset(), false, liquid);
            requestableWithdrawal.outputs[1] = WithdrawalOutput(withdrawalToken, true, assets - liquid);
        } else {
            requestableWithdrawal.outputs = new WithdrawalOutput[](1);
            requestableWithdrawal.outputs[0] = WithdrawalOutput(IERC4626(token).asset(), false, assets);
        }

        requestableWithdrawal.requestCalls = new MultiCall[](2);

        address creditManager = ICreditAccountV3(creditAccount).creditManager();

        address vaultAdapter = ICreditManagerV3(creditManager).contractToAdapter(token);

        requestableWithdrawal.requestCalls[0] = MultiCall({
            target: vaultAdapter,
            callData: abi.encodeCall(IERC4626Adapter.redeem, (amount, address(0), address(0)))
        });

        address claimer = MellowWithdrawalPhantomToken(withdrawalToken).claimer();

        address claimerAdapter = ICreditManagerV3(creditManager).contractToAdapter(claimer);

        (uint256[] memory subvaultIndices, uint256[][] memory withdrawalIndices) =
            IMellowClaimerAdapter(claimerAdapter).getMultiVaultSubvaultIndices(token);

        requestableWithdrawal.requestCalls[1] = MultiCall({
            target: claimerAdapter,
            callData: abi.encodeCall(IMellowClaimerAdapter.multiAccept, (token, subvaultIndices, withdrawalIndices))
        });

        requestableWithdrawal.claimableAt = block.timestamp + _getWithdrawalLength(token);

        return requestableWithdrawal;
    }

    function _getPendingWithdrawals(address creditAccount, address multiVault)
        internal
        view
        returns (PendingWithdrawal[] memory pendingWithdrawals)
    {
        address asset = IERC4626(multiVault).asset();

        uint256 nSubvaults = IMellowMultiVault(multiVault).subvaultsCount();

        for (uint256 i = 0; i < nSubvaults; ++i) {
            Subvault memory subvault = IMellowMultiVault(multiVault).subvaultAt(i);

            if (subvault.withdrawalQueue == address(0)) continue;

            uint256 pendingAssets = IMellowWithdrawalQueue(subvault.withdrawalQueue).pendingAssetsOf(creditAccount);

            if (pendingAssets > 0) {
                pendingWithdrawals = pendingWithdrawals.concat(
                    _getSubvaultPendingWithdrawals(
                        creditAccount, multiVault, subvault.protocol, subvault.vault, subvault.withdrawalQueue, asset
                    )
                );
            }
        }

        return pendingWithdrawals;
    }

    function _getSubvaultPendingWithdrawals(
        address creditAccount,
        address multiVault,
        MellowProtocol protocol,
        address subvault,
        address withdrawalQueue,
        address asset
    ) internal view returns (PendingWithdrawal[] memory pendingWithdrawals) {
        if (protocol == MellowProtocol.SYMBIOTIC) {
            (uint256 sharesToClaimPrev, uint256 sharesToClaim,, uint256 claimEpoch) =
                ISymbioticWithdrawalQueue(withdrawalQueue).getAccountData(creditAccount);

            uint256 currentEpoch = ISymbioticWithdrawalQueue(withdrawalQueue).getCurrentEpoch();

            if (claimEpoch < currentEpoch) {
                return pendingWithdrawals;
            } else if (claimEpoch == currentEpoch) {
                pendingWithdrawals = new PendingWithdrawal[](1);
                pendingWithdrawals[0].token = multiVault;
                pendingWithdrawals[0].expectedOutputs = new WithdrawalOutput[](1);

                uint256 expectedAmount =
                    _getSymbioticExpectedWithdrawal(subvault, withdrawalQueue, sharesToClaim, currentEpoch);

                pendingWithdrawals[0].expectedOutputs[0] = WithdrawalOutput(asset, false, expectedAmount);
                pendingWithdrawals[0].claimableAt = ISymbioticSubvault(subvault).nextEpochStart();
            } else if (claimEpoch == currentEpoch + 1) {
                pendingWithdrawals = new PendingWithdrawal[](2);

                pendingWithdrawals[0].token = multiVault;
                pendingWithdrawals[0].expectedOutputs = new WithdrawalOutput[](1);

                uint256 expectedAmount =
                    _getSymbioticExpectedWithdrawal(subvault, withdrawalQueue, sharesToClaim, currentEpoch + 1);

                pendingWithdrawals[0].expectedOutputs[0] = WithdrawalOutput(asset, false, expectedAmount);
                pendingWithdrawals[0].claimableAt =
                    ISymbioticSubvault(subvault).nextEpochStart() + ISymbioticSubvault(subvault).epochDuration();

                if (sharesToClaimPrev > 0) {
                    pendingWithdrawals[1].token = multiVault;
                    pendingWithdrawals[1].expectedOutputs = new WithdrawalOutput[](1);

                    expectedAmount =
                        _getSymbioticExpectedWithdrawal(subvault, withdrawalQueue, sharesToClaimPrev, currentEpoch);

                    pendingWithdrawals[1].expectedOutputs[0] = WithdrawalOutput(asset, false, expectedAmount);
                    pendingWithdrawals[1].claimableAt = ISymbioticSubvault(subvault).nextEpochStart();
                }
            }
        }

        if (protocol == MellowProtocol.EIGEN_LAYER) {
            (, uint256[] memory withdrawals,) =
                IEigenLayerWithdrawalQueueExt(withdrawalQueue).getAccountData(creditAccount, type(uint256).max, 0, 0, 0);

            uint256 latestWithdrawableBlock = IEigenLayerWithdrawalQueueExt(withdrawalQueue).latestWithdrawableBlock();

            pendingWithdrawals = new PendingWithdrawal[](withdrawals.length);

            for (uint256 i = 0; i < withdrawals.length; ++i) {
                (EigenLayerWithdrawal memory withdrawal,,, uint256 shares, uint256 accountShares) =
                    IEigenLayerWithdrawalQueueExt(withdrawalQueue).getWithdrawalRequest(withdrawals[i], creditAccount);

                if (withdrawal.startBlock > latestWithdrawableBlock && accountShares > 0) {
                    pendingWithdrawals[i].token = multiVault;
                    pendingWithdrawals[i].expectedOutputs = new WithdrawalOutput[](1);

                    uint256 unscaledShares = IEigenLayerWithdrawalQueueExt(withdrawalQueue).convertScaledSharesToShares(
                        withdrawal, accountShares, shares
                    );

                    uint256 expectedAmount = IEigenLayerIsolatedVault(
                        IEigenLayerWithdrawalQueueExt(withdrawalQueue).isolatedVault()
                    ).sharesToUnderlyingView(IEigenLayerWithdrawalQueueExt(withdrawalQueue).strategy(), unscaledShares);

                    pendingWithdrawals[i].expectedOutputs[0] = WithdrawalOutput(asset, false, expectedAmount);
                    pendingWithdrawals[i].claimableAt =
                        block.timestamp + 12 * (withdrawal.startBlock - latestWithdrawableBlock);
                }
            }
        }
    }

    function _getClaimableWithdrawal(address creditAccount, address withdrawalToken, address multiVault)
        internal
        view
        returns (ClaimableWithdrawal memory withdrawal)
    {
        address asset = IERC4626(multiVault).asset();

        withdrawal.token = multiVault;
        withdrawal.outputs = new WithdrawalOutput[](1);
        withdrawal.outputs[0] = WithdrawalOutput(asset, false, 0);

        uint256 nSubvaults = IMellowMultiVault(multiVault).subvaultsCount();

        for (uint256 i = 0; i < nSubvaults; ++i) {
            Subvault memory subvault = IMellowMultiVault(multiVault).subvaultAt(i);

            if (subvault.withdrawalQueue == address(0)) continue;

            uint256 claimableAssets = IMellowWithdrawalQueue(subvault.withdrawalQueue).claimableAssetsOf(creditAccount);

            withdrawal.outputs[0].amount += claimableAssets;
        }

        if (withdrawal.outputs[0].amount == 0) {
            return withdrawal;
        }

        withdrawal.claimCalls = new MultiCall[](1);

        address claimerAdapter;

        {
            address claimer = MellowWithdrawalPhantomToken(withdrawalToken).claimer();
            address creditManager = ICreditAccountV3(creditAccount).creditManager();

            claimerAdapter = ICreditManagerV3(creditManager).contractToAdapter(claimer);
        }

        (uint256[] memory subvaultIndices, uint256[][] memory withdrawalIndices) =
            IMellowClaimerAdapter(claimerAdapter).getUserSubvaultIndices(multiVault, creditAccount);

        withdrawal.claimCalls[0] = MultiCall(
            address(claimerAdapter),
            abi.encodeWithSelector(
                IMellowClaimerAdapter.multiAcceptAndClaim.selector,
                multiVault,
                subvaultIndices,
                withdrawalIndices,
                creditAccount,
                withdrawal.outputs[0].amount
            )
        );

        return withdrawal;
    }

    function _getWithdrawalLength(address multiVault) internal view returns (uint256) {
        uint256 withdrawalLength = 0;

        uint256 nSubvaults = IMellowMultiVault(multiVault).subvaultsCount();

        for (uint256 i = 0; i < nSubvaults; ++i) {
            Subvault memory subvault = IMellowMultiVault(multiVault).subvaultAt(i);

            if (subvault.protocol == MellowProtocol.SYMBIOTIC) {
                uint256 symbioticWithdrawalLength = ISymbioticSubvault(subvault.vault).nextEpochStart()
                    + ISymbioticSubvault(subvault.vault).epochDuration() - block.timestamp;
                if (symbioticWithdrawalLength > withdrawalLength) {
                    withdrawalLength = symbioticWithdrawalLength;
                }
            }

            if (subvault.protocol == MellowProtocol.EIGEN_LAYER) {
                uint256 eigenLayerWithdrawalLength = IEigenLayerDelegation(
                    IEigenLayerWithdrawalQueueExt(subvault.withdrawalQueue).delegation()
                ).minWithdrawalDelayBlocks() * 12;
                if (eigenLayerWithdrawalLength > withdrawalLength) {
                    withdrawalLength = eigenLayerWithdrawalLength;
                }
            }
        }

        return withdrawalLength;
    }

    function _getSymbioticExpectedWithdrawal(
        address subvault,
        address withdrawalQueue,
        uint256 sharesToClaim,
        uint256 epoch
    ) internal view returns (uint256) {
        EpochData memory epochData = ISymbioticWithdrawalQueue(withdrawalQueue).getEpochData(epoch);

        uint256 totalWithdrawals = ISymbioticSubvault(subvault).withdrawalsOf(epoch, withdrawalQueue);

        return sharesToClaim * totalWithdrawals / epochData.sharesToClaim;
    }
}
