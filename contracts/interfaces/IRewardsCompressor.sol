// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

/// @title Reward info struct
struct RewardInfo {
    uint256 amount;
    address rewardToken;
    address stakedPhantomToken;
    address adapter;
}

/// @title Reward info array operations library
library RewardInfoLib {
    /// @notice Appends a single RewardInfo to an array
    /// @param rewards Original array of RewardInfo
    /// @param reward Single RewardInfo to append
    /// @return newRewards New array with appended RewardInfo
    function append(RewardInfo[] memory rewards, RewardInfo memory reward)
        internal
        pure
        returns (RewardInfo[] memory newRewards)
    {
        newRewards = new RewardInfo[](rewards.length + 1);
        for (uint256 i = 0; i < rewards.length; ++i) {
            newRewards[i] = rewards[i];
        }
        newRewards[rewards.length] = reward;
    }

    /// @notice Concatenates two RewardInfo arrays
    /// @param rewards1 First array of RewardInfo
    /// @param rewards2 Second array of RewardInfo
    /// @return newRewards New concatenated array
    function concat(RewardInfo[] memory rewards1, RewardInfo[] memory rewards2)
        internal
        pure
        returns (RewardInfo[] memory newRewards)
    {
        newRewards = new RewardInfo[](rewards1.length + rewards2.length);
        for (uint256 i = 0; i < rewards1.length; ++i) {
            newRewards[i] = rewards1[i];
        }
        for (uint256 i = 0; i < rewards2.length; ++i) {
            newRewards[rewards1.length + i] = rewards2[i];
        }
    }
}

/// @title Modified Booster interface for Aura L1
interface IModifiedBooster {
    function getRewardMultipliers(address pool) external view returns (uint256);
}

/// @title L2 coordinator interface for Aura L2
interface IAuraL2Coordinator {
    function auraOFT() external view returns (address);
    function mintRate() external view returns (uint256);
}

/// @title Convex/Aura token interface
interface IConvexToken {
    function totalSupply() external view returns (uint256);
    function maxSupply() external view returns (uint256);
    function reductionPerCliff() external view returns (uint256);
    function totalCliffs() external view returns (uint256);
    function EMISSIONS_MAX_SUPPLY() external view returns (uint256);
}

/// @title Rewards compressor interface
/// @notice Compresses information about earned rewards for various staking adapters
interface IRewardsCompressor is IVersion {
    /// @notice Returns array of earned rewards for a credit account across all adapters
    /// @param creditAccount Address of the credit account to check
    /// @return rewards Array of RewardInfo structs containing reward information
    function getRewards(address creditAccount) external view returns (RewardInfo[] memory rewards);
}
