// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";

import {IACL} from "@gearbox-protocol/governance/contracts/interfaces/IACL.sol";
import {IAdapter} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IAdapter.sol";

import {ConvexStakedPositionToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/convex/ConvexV1_StakedPositionToken.sol";
import {StakingRewardsPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/sky/StakingRewardsPhantomToken.sol";
import {IBaseRewardPool} from "@gearbox-protocol/integrations-v3/contracts/integrations/convex/IBaseRewardPool.sol";

import {UniswapV2Adapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/uniswap/UniswapV2.sol";
import {UniswapV3Adapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/uniswap/UniswapV3.sol";
import {YearnV2Adapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/yearn/YearnV2.sol";
import {ERC4626Adapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/erc4626/ERC4626Adapter.sol";
import {LidoV1Adapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/lido/LidoV1.sol";
import {WstETHV1Adapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/lido/WstETHV1.sol";
import {BalancerV2VaultAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/adapters/balancer/BalancerV2VaultAdapter.sol";
import {CamelotV3Adapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/camelot/CamelotV3Adapter.sol";
import {PendleRouterAdapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/pendle/PendleRouterAdapter.sol";
import {PendlePairStatus} from "@gearbox-protocol/integrations-v3/contracts/interfaces/pendle/IPendleRouterAdapter.sol";
import {CurveV1Adapter2Assets} from "@gearbox-protocol/integrations-v3/contracts/adapters/curve/CurveV1_2.sol";
import {CurveV1Adapter3Assets} from "@gearbox-protocol/integrations-v3/contracts/adapters/curve/CurveV1_3.sol";
import {CurveV1Adapter4Assets} from "@gearbox-protocol/integrations-v3/contracts/adapters/curve/CurveV1_4.sol";
import {ConvexV1BaseRewardPoolAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/adapters/convex/ConvexV1_BaseRewardPool.sol";
import {ConvexV1BoosterAdapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/convex/ConvexV1_Booster.sol";
import {VelodromeV2RouterAdapter} from
    "@gearbox-protocol/integrations-v3/contracts/adapters/velodrome/VelodromeV2RouterAdapter.sol";
import {DaiUsdsAdapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/sky/DaiUsdsAdapter.sol";
import {StakingRewardsAdapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/sky/StakingRewardsAdapter.sol";
import {MellowVaultAdapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/mellow/MellowVaultAdapter.sol";

interface IOldAdapter {
    function _gearboxAdapterType() external view returns (AdapterType aType);
}

contract IntegrationsMigrator is Script, Test {
    string[18] convexPTSymbols = [
        "stkcvx3Crv",
        "stkcvxFRAX3CRV-f",
        "stkcvxgusd3CRV",
        "stkcvxsteCRV",
        "stkcvxcrvPlain3andSUSD",
        "stkcvxLUSD3CRV-f",
        "stkcvxcrvFRAX",
        "stkcvxOHMFRAXBP-f",
        "stkcvxMIM-3LP3CRV-f",
        "stkcvxcrvCRVETH",
        "stkcvxcrvCVXETH",
        "stkcvxcrvUSDTWBTCWETH",
        "stkcvxLDOETH-f",
        "stkcvxcrvUSDUSDC-f",
        "stkcvxcrvUSDUSDT-f",
        "stkcvxcrvUSDFRAX-f",
        "stkcvxcrvUSDETHCRV",
        "stkcvxGHOcrvUSD"
    ];

    uint256 deployerPrivateKey;

    mapping(address => address) public oldToNewPhantomToken;
    mapping(address => address) public oldToNewAdapter;

    constructor(uint256 _pkey) {
        deployerPrivateKey = _pkey;
    }

    function migratePhantomToken(address oldToken) external returns (address newToken) {
        if (oldToNewPhantomToken[oldToken] != address(0)) return oldToNewPhantomToken[oldToken];

        string memory symbol = ERC20(oldToken).symbol();

        uint8 phantomTokenType = _getPhantomTokenType(symbol);

        if (phantomTokenType == 0) {
            return address(0);
        } else if (phantomTokenType == 1) {
            address pool = ConvexStakedPositionToken(oldToken).pool();
            address lpToken = ConvexStakedPositionToken(oldToken).underlying();
            address booster = IBaseRewardPool(pool).operator();

            vm.broadcast(deployerPrivateKey);
            newToken = address(new ConvexStakedPositionToken(pool, lpToken, booster));
        }

        oldToNewPhantomToken[oldToken] = newToken;
    }

    function _getPhantomTokenType(string memory symbol) internal view returns (uint8) {
        for (uint256 i = 0; i < convexPTSymbols.length; ++i) {
            if (keccak256(abi.encode(symbol)) == keccak256(abi.encode(convexPTSymbols[i]))) return 1;
        }

        return 0;
    }

    function migrateAdapter(address oldAdapter) external returns (address newAdapter) {
        AdapterType aType = IOldAdapter(oldAdapter)._gearboxAdapterType();

        address creditManager = IAdapter(oldAdapter).creditManager();
        address targetContract = IAdapter(oldAdapter).targetContract();

        /// UNISWAP V2
        if (aType == AdapterType.UNISWAP_V2_ROUTER) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new UniswapV2Adapter(creditManager, targetContract));

            /// CLONE UNI V2 PAIRS
        }
        /// UNISWAP V3
        else if (aType == AdapterType.UNISWAP_V3_ROUTER) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new UniswapV3Adapter(creditManager, targetContract));

            /// CLONE UNI V3 PAIRS
        }
        /// YEARN V2
        else if (aType == AdapterType.YEARN_V2) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new YearnV2Adapter(creditManager, targetContract));
        }
        /// ERC4626
        else if (aType == AdapterType.ERC4626_VAULT) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new ERC4626Adapter(creditManager, targetContract));
        }
        /// LIDO V1
        else if (aType == AdapterType.LIDO_V1) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new LidoV1Adapter(creditManager, targetContract));
        }
        /// WSTETH V1
        else if (aType == AdapterType.LIDO_WSTETH_V1) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new WstETHV1Adapter(creditManager, targetContract));
        }
        /// BALANCER VAULT
        else if (aType == AdapterType.BALANCER_VAULT) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new BalancerV2VaultAdapter(creditManager, targetContract));

            /// CLONE BALANCER POOLS
        }
        /// CAMELOT V3
        else if (aType == AdapterType.CAMELOT_V3_ROUTER) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new CamelotV3Adapter(creditManager, targetContract));

            /// CLONE CAMELOT POOLS
        }
        /// VELODROME V2
        else if (aType == AdapterType.VELODROME_V2_ROUTER) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new VelodromeV2RouterAdapter(creditManager, targetContract));

            /// CLONE VELODROME POOLS
        }
        /// PENDLE ROUTER
        else if (aType == AdapterType.PENDLE_ROUTER) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new PendleRouterAdapter(creditManager, targetContract));

            PendlePairStatus[] memory pendlePairs = PendleRouterAdapter(oldAdapter).getAllowedPairs();

            vm.broadcast(deployerPrivateKey);
            PendleRouterAdapter(newAdapter).setPairStatusBatch(pendlePairs);
        }
        /// CURVE V1 2 ASSETS
        else if (aType == AdapterType.CURVE_V1_2ASSETS) {
            address lpToken = CurveV1Adapter2Assets(oldAdapter).lp_token();
            address metapoolBase = CurveV1Adapter2Assets(oldAdapter).metapoolBase();

            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new CurveV1Adapter2Assets(creditManager, targetContract, lpToken, metapoolBase));
        }
        /// CURVE V1 3 ASSETS
        else if (aType == AdapterType.CURVE_V1_3ASSETS) {
            address lpToken = CurveV1Adapter3Assets(oldAdapter).lp_token();
            address metapoolBase = CurveV1Adapter3Assets(oldAdapter).metapoolBase();

            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new CurveV1Adapter3Assets(creditManager, targetContract, lpToken, metapoolBase));
        }
        /// CURVE V1 4 ASSETS
        else if (aType == AdapterType.CURVE_V1_4ASSETS) {
            address lpToken = CurveV1Adapter4Assets(oldAdapter).lp_token();
            address metapoolBase = CurveV1Adapter4Assets(oldAdapter).metapoolBase();

            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new CurveV1Adapter4Assets(creditManager, targetContract, lpToken, metapoolBase));
        }
        /// CONVEX V1 BASE REWARD POOL
        else if (aType == AdapterType.CONVEX_V1_BASE_REWARD_POOL) {
            address stakedPhantomToken =
                oldToNewPhantomToken[ConvexV1BaseRewardPoolAdapter(oldAdapter).stakedPhantomToken()];

            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new ConvexV1BaseRewardPoolAdapter(creditManager, targetContract, stakedPhantomToken));
        }
        /// CONVEX V1 BOOSTER
        else if (aType == AdapterType.CONVEX_V1_BOOSTER) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new ConvexV1BoosterAdapter(creditManager, targetContract));
        }
        /// DAI USDS
        else if (aType == AdapterType.DAI_USDS_EXCHANGE) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new DaiUsdsAdapter(creditManager, targetContract));
        }
        /// STAKING REWARDS
        else if (aType == AdapterType.STAKING_REWARDS) {
            address stakedPhantomToken = oldToNewPhantomToken[StakingRewardsAdapter(oldAdapter).stakedPhantomToken()];

            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new StakingRewardsAdapter(creditManager, targetContract, stakedPhantomToken));
        }
        /// MELLOW LRT VAULT
        else if (aType == AdapterType.MELLOW_LRT_VAULT) {
            vm.broadcast(deployerPrivateKey);
            newAdapter = address(new MellowVaultAdapter(creditManager, targetContract));

            /// CLONE MELLOW UNDERLYINGS
        }

        oldToNewAdapter[oldAdapter] = newAdapter;
    }

    function configureAdapters(address[] memory adapters) external {
        for (uint256 i = 0; i < adapters.length; ++i) {
            if (IAdapter(adapters[i]).contractType() == "AD_CONVEX_V1_BOOSTER") {
                vm.broadcast(deployerPrivateKey);
                ConvexV1BoosterAdapter(adapters[i]).updateSupportedPids();
            }
        }
    }
}
