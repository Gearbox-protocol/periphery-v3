// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    IRewardsCompressor,
    RewardInfo,
    RewardInfoLib,
    IModifiedBooster,
    IAuraL2Coordinator,
    IConvexToken
} from "../interfaces/IRewardsCompressor.sol";

import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";

import {IConvexV1BaseRewardPoolAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/convex/IConvexV1BaseRewardPoolAdapter.sol";
import {IStakingRewardsAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/sky/IStakingRewardsAdapter.sol";
import {IBaseRewardPool} from "@gearbox-protocol/integrations-v3/contracts/integrations/convex/IBaseRewardPool.sol";
import {IBooster} from "@gearbox-protocol/integrations-v3/contracts/integrations/convex/IBooster.sol";
import {IStakingRewards} from "@gearbox-protocol/integrations-v3/contracts/integrations/sky/IStakingRewards.sol";

import {AP_REWARDS_COMPRESSOR} from "../libraries/Literals.sol";

interface ILegacyAdapter {
    function _gearboxAdapterVersion() external view returns (uint16);
    function _gearboxAdapterType() external view returns (uint8);
}

/// @title Rewards compressor
/// @notice Compresses information about earned rewards for various staking adapters
contract RewardsCompressor is IRewardsCompressor {
    using RewardInfoLib for RewardInfo[];

    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = AP_REWARDS_COMPRESSOR;

    /// @notice Returns array of earned rewards for a credit account across all adapters
    /// @param creditAccount Address of the credit account to check
    /// @return rewards Array of RewardInfo structs containing reward information
    function getRewards(address creditAccount) external view returns (RewardInfo[] memory rewards) {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        address[] memory adapters = ICreditConfiguratorV3(creditConfigurator).allowedAdapters();

        rewards = new RewardInfo[](0);
        for (uint256 i = 0; i < adapters.length; ++i) {
            bytes32 adapterType = _getAdapterType(adapters[i]);

            if (adapterType == "ADAPTER::CVX_V1_BASE_REWARD_POOL") {
                rewards = rewards.concat(_getConvexRewards(adapters[i], creditAccount));
            } else if (adapterType == "ADAPTER::STAKING_REWARDS") {
                rewards = rewards.concat(_getStakingRewards(adapters[i], creditAccount));
            }
        }
    }

    /// @dev Returns array of Convex/Aura rewards
    function _getConvexRewards(address adapter, address creditAccount)
        internal
        view
        returns (RewardInfo[] memory rewards)
    {
        IConvexV1BaseRewardPoolAdapter convexAdapter = IConvexV1BaseRewardPoolAdapter(adapter);
        IBaseRewardPool rewardPool = IBaseRewardPool(convexAdapter.targetContract());
        address stakedPhantomToken = convexAdapter.stakedPhantomToken();

        rewards = new RewardInfo[](0);

        // Get base and secondary rewards
        rewards = _getBaseAndSecondaryRewards(adapter, creditAccount, rewardPool, stakedPhantomToken);

        // Get extra rewards
        rewards =
            rewards.concat(_getExtraRewards(adapter, creditAccount, convexAdapter, rewardPool, stakedPhantomToken));
    }

    /// @dev Gets base (CRV/BAL) and secondary (CVX/AURA) rewards
    function _getBaseAndSecondaryRewards(
        address adapter,
        address creditAccount,
        IBaseRewardPool rewardPool,
        address stakedPhantomToken
    ) internal view returns (RewardInfo[] memory rewards) {
        rewards = new RewardInfo[](0);
        uint256 baseAmount = rewardPool.earned(creditAccount);

        if (baseAmount > 0) {
            // Add base reward
            rewards = rewards.append(
                RewardInfo({
                    amount: baseAmount,
                    rewardToken: address(rewardPool.rewardToken()),
                    stakedPhantomToken: stakedPhantomToken,
                    adapter: adapter
                })
            );

            // Get and add secondary reward if any
            address booster = rewardPool.operator();
            address minter = IBooster(booster).minter();
            (uint256 secondaryAmount, address secondaryToken) =
                _getSecondaryReward(baseAmount, booster, minter, rewardPool);

            if (secondaryAmount > 0) {
                rewards = rewards.append(
                    RewardInfo({
                        amount: secondaryAmount,
                        rewardToken: secondaryToken,
                        stakedPhantomToken: stakedPhantomToken,
                        adapter: adapter
                    })
                );
            }
        }
    }

    /// @dev Gets extra rewards from the reward pool
    function _getExtraRewards(
        address adapter,
        address creditAccount,
        IConvexV1BaseRewardPoolAdapter convexAdapter,
        IBaseRewardPool rewardPool,
        address stakedPhantomToken
    ) internal view returns (RewardInfo[] memory rewards) {
        address[4] memory extraRewards =
            [convexAdapter.extraReward1(), convexAdapter.extraReward2(), address(0), address(0)];

        try convexAdapter.extraReward3() returns (address extraReward3) {
            extraRewards[2] = extraReward3;
        } catch {}

        try convexAdapter.extraReward4() returns (address extraReward4) {
            extraRewards[3] = extraReward4;
        } catch {}

        uint256 extraRewardsLength = rewardPool.extraRewardsLength();
        rewards = new RewardInfo[](0);

        for (uint256 i = 0; i < extraRewardsLength && i < 4; ++i) {
            if (extraRewards[i] == address(0)) continue;

            IBaseRewardPool extraRewardPool = IBaseRewardPool(rewardPool.extraRewards(i));
            uint256 extraRewardAmount = extraRewardPool.earned(creditAccount);

            if (extraRewardAmount > 0) {
                rewards = rewards.append(
                    RewardInfo({
                        amount: extraRewardAmount,
                        rewardToken: extraRewards[i],
                        stakedPhantomToken: stakedPhantomToken,
                        adapter: adapter
                    })
                );
            }
        }
    }

    /// @dev Computes secondary reward token (CVX/AURA) amount and address
    function _getSecondaryReward(uint256 baseAmount, address booster, address minter, IBaseRewardPool rewardPool)
        internal
        view
        returns (uint256 amount, address token)
    {
        // Try L2 Aura first
        try IAuraL2Coordinator(minter).auraOFT() returns (address auraToken) {
            amount = baseAmount * IAuraL2Coordinator(minter).mintRate() / 1e18;
            token = auraToken;
            return (amount, token);
        } catch {}

        // Try L1 Aura
        try IModifiedBooster(booster).getRewardMultipliers(address(rewardPool)) returns (uint256 multiplier) {
            amount = _computeAURA(baseAmount * multiplier / 10000, IConvexToken(minter));
            token = minter;
            return (amount, token);
        } catch {}

        // Must be Convex
        amount = _computeCVX(baseAmount, IConvexToken(minter));
        token = minter;
        return (amount, token);
    }

    /// @dev Computes how much CVX should be minted for provided amount of CRV
    function _computeCVX(uint256 amount, IConvexToken cvx) internal view returns (uint256) {
        uint256 supply = cvx.totalSupply();
        if (supply == 0) {
            return amount;
        }

        uint256 cliff = supply / cvx.reductionPerCliff();
        uint256 totalCliffs = cvx.totalCliffs();

        if (cliff < totalCliffs) {
            uint256 reduction = totalCliffs - cliff;
            amount = (amount * reduction) / totalCliffs;

            uint256 amtTillMax = cvx.maxSupply() - supply;
            if (amount > amtTillMax) {
                amount = amtTillMax;
            }

            return amount;
        }

        return 0;
    }

    /// @dev Computes how much AURA should be minted for provided amount of BAL
    function _computeAURA(uint256 amount, IConvexToken aura) internal view returns (uint256) {
        uint256 supply = aura.totalSupply();
        if (supply == 0) {
            return amount;
        }

        uint256 emissionsMinted = supply - 5e25;
        uint256 cliff = emissionsMinted / aura.reductionPerCliff();
        uint256 totalCliffs = aura.totalCliffs();

        if (cliff < totalCliffs) {
            uint256 reduction = 700 + (totalCliffs - cliff) * 5 / 2;
            amount = (amount * reduction) / totalCliffs;

            uint256 amtTillMax = aura.EMISSIONS_MAX_SUPPLY() - emissionsMinted;
            if (amount > amtTillMax) {
                amount = amtTillMax;
            }

            return amount;
        }

        return 0;
    }

    /// @dev Returns array of StakingRewards rewards
    function _getStakingRewards(address adapter, address creditAccount)
        internal
        view
        returns (RewardInfo[] memory rewards)
    {
        IStakingRewardsAdapter stakingAdapter = IStakingRewardsAdapter(adapter);
        IStakingRewards stakingRewards = IStakingRewards(stakingAdapter.targetContract());

        uint256 earnedAmount = stakingRewards.earned(creditAccount);

        rewards = new RewardInfo[](earnedAmount > 0 ? 1 : 0);
        if (earnedAmount > 0) {
            rewards[0] = RewardInfo({
                amount: earnedAmount,
                rewardToken: stakingAdapter.rewardsToken(),
                stakedPhantomToken: stakingAdapter.stakedPhantomToken(),
                adapter: adapter
            });
        }
    }

    function _getAdapterType(address adapter) internal view returns (bytes32) {
        try IVersion(adapter).contractType() returns (bytes32 adapterType) {
            return adapterType;
        } catch {
            uint8 adapterType = ILegacyAdapter(adapter)._gearboxAdapterType();
            if (adapterType == uint8(AdapterType.CONVEX_V1_BASE_REWARD_POOL)) {
                return "ADAPTER::CVX_V1_BASE_REWARD_POOL";
            } else if (adapterType == uint8(AdapterType.STAKING_REWARDS)) {
                return "ADAPTER::STAKING_REWARDS";
            } else {
                return "ADAPTER::IRRELEVANT";
            }
        }
    }
}
