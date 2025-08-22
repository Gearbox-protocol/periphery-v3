// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

struct WithdrawalOutput {
    address token;
    bool isDelayed;
    uint256 amount;
}

struct WithdrawableAsset {
    address token;
    address withdrawalPhantomToken;
    address underlying;
    uint256 withdrawalLength;
}

struct RequestableWithdrawal {
    address token;
    uint256 amountIn;
    WithdrawalOutput[] outputs;
    MultiCall[] requestCalls;
    uint256 claimableAt;
}

struct ClaimableWithdrawal {
    address token;
    WithdrawalOutput[] outputs;
    MultiCall[] claimCalls;
}

struct PendingWithdrawal {
    address token;
    WithdrawalOutput[] expectedOutputs;
    uint256 claimableAt;
}

library WithdrawalLib {
    function push(WithdrawableAsset[] memory w, WithdrawableAsset memory asset)
        internal
        pure
        returns (WithdrawableAsset[] memory)
    {
        WithdrawableAsset[] memory newWithdrawableAssets = new WithdrawableAsset[](w.length + 1);
        for (uint256 i = 0; i < w.length; i++) {
            newWithdrawableAssets[i] = w[i];
        }
        newWithdrawableAssets[w.length] = asset;
        return newWithdrawableAssets;
    }

    function concat(WithdrawableAsset[] memory w0, WithdrawableAsset[] memory w1)
        internal
        pure
        returns (WithdrawableAsset[] memory)
    {
        WithdrawableAsset[] memory newWithdrawableAssets = new WithdrawableAsset[](w0.length + w1.length);
        for (uint256 i = 0; i < w0.length; i++) {
            newWithdrawableAssets[i] = w0[i];
        }
        for (uint256 i = 0; i < w1.length; i++) {
            newWithdrawableAssets[w0.length + i] = w1[i];
        }
        return newWithdrawableAssets;
    }

    function concat(RequestableWithdrawal[] memory w0, RequestableWithdrawal[] memory w1)
        internal
        pure
        returns (RequestableWithdrawal[] memory)
    {
        RequestableWithdrawal[] memory withdrawals = new RequestableWithdrawal[](w0.length + w1.length);
        for (uint256 i = 0; i < w0.length; i++) {
            withdrawals[i] = w0[i];
        }
        for (uint256 i = 0; i < w1.length; i++) {
            withdrawals[w0.length + i] = w1[i];
        }
        return withdrawals;
    }

    function push(ClaimableWithdrawal[] memory w, ClaimableWithdrawal memory withdrawal)
        internal
        pure
        returns (ClaimableWithdrawal[] memory)
    {
        ClaimableWithdrawal[] memory newClaimableWithdrawals = new ClaimableWithdrawal[](w.length + 1);
        for (uint256 i = 0; i < w.length; i++) {
            newClaimableWithdrawals[i] = w[i];
        }
        newClaimableWithdrawals[w.length] = withdrawal;
        return newClaimableWithdrawals;
    }

    function concat(ClaimableWithdrawal[] memory w0, ClaimableWithdrawal[] memory w1)
        internal
        pure
        returns (ClaimableWithdrawal[] memory)
    {
        ClaimableWithdrawal[] memory withdrawals = new ClaimableWithdrawal[](w0.length + w1.length);
        for (uint256 i = 0; i < w0.length; i++) {
            withdrawals[i] = w0[i];
        }
        for (uint256 i = 0; i < w1.length; i++) {
            withdrawals[w0.length + i] = w1[i];
        }
        return withdrawals;
    }

    function push(PendingWithdrawal[] memory w, PendingWithdrawal memory withdrawal)
        internal
        pure
        returns (PendingWithdrawal[] memory)
    {
        PendingWithdrawal[] memory newPendingWithdrawals = new PendingWithdrawal[](w.length + 1);
        for (uint256 i = 0; i < w.length; i++) {
            newPendingWithdrawals[i] = w[i];
        }
        newPendingWithdrawals[w.length] = withdrawal;
        return newPendingWithdrawals;
    }

    function concat(PendingWithdrawal[] memory w0, PendingWithdrawal[] memory w1)
        internal
        pure
        returns (PendingWithdrawal[] memory)
    {
        PendingWithdrawal[] memory withdrawals = new PendingWithdrawal[](w0.length + w1.length);
        for (uint256 i = 0; i < w0.length; i++) {
            withdrawals[i] = w0[i];
        }
        for (uint256 i = 0; i < w1.length; i++) {
            withdrawals[w0.length + i] = w1[i];
        }
        return withdrawals;
    }

    function filterEmpty(PendingWithdrawal[] memory pendingWithdrawals)
        internal
        pure
        returns (PendingWithdrawal[] memory)
    {
        PendingWithdrawal[] memory filteredPendingWithdrawals = new PendingWithdrawal[](0);
        for (uint256 i = 0; i < pendingWithdrawals.length; i++) {
            if (pendingWithdrawals[i].expectedOutputs.length > 0) {
                for (uint256 j = 0; j < pendingWithdrawals[i].expectedOutputs.length; j++) {
                    if (pendingWithdrawals[i].expectedOutputs[j].amount > 0) {
                        filteredPendingWithdrawals = push(filteredPendingWithdrawals, pendingWithdrawals[i]);
                        break;
                    }
                }
            }
        }

        return filteredPendingWithdrawals;
    }

    function filterEmpty(ClaimableWithdrawal[] memory claimableWithdrawals)
        internal
        pure
        returns (ClaimableWithdrawal[] memory)
    {
        ClaimableWithdrawal[] memory filteredClaimableWithdrawals = new ClaimableWithdrawal[](0);
        for (uint256 i = 0; i < claimableWithdrawals.length; i++) {
            if (claimableWithdrawals[i].outputs.length > 0) {
                for (uint256 j = 0; j < claimableWithdrawals[i].outputs.length; j++) {
                    if (claimableWithdrawals[i].outputs[j].amount > 0) {
                        filteredClaimableWithdrawals = push(filteredClaimableWithdrawals, claimableWithdrawals[i]);
                        break;
                    }
                }
            }
        }

        return filteredClaimableWithdrawals;
    }
}
