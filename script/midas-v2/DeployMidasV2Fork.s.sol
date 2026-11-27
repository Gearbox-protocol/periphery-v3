// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {console2} from "forge-std/console2.sol";

import {MidasV2Deployer} from "../../contracts/test/midas-v2/MidasV2Deployer.sol";

/// @notice Deploys the midas v2 fork stack onto an already-running mainnet fork.
/// @dev Does not create a fork. Point `--rpc-url` at Anvil (or similar) that is
///      already forked from mainnet, and use `--broadcast` so state persists.
///
/// Example:
///   FOUNDRY_PROFILE=midas_fork forge script script/midas-v2/DeployMidasV2Fork.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast -vv
contract DeployMidasV2Fork is MidasV2Deployer {
    bool public IS_SCRIPT = true;

    function run() external returns (Deployment memory d) {
        require(block.chainid == 1, "expected mainnet fork (chainid 1)");

        d = deploy();

        console2.log("=== Midas V2 fork deployment ===");
        console2.log("proxyAdmin       ", d.proxyAdmin);
        console2.log("accessControl    ", d.accessControl);
        console2.log("pauseManager     ", d.pauseManager);
        console2.log("timelockManager  ", d.timelockManager);
        console2.log("mglobalFeed      ", d.mglobalFeed);
        console2.log("requestRedeemer  ", d.requestRedeemer);
        console2.log("mfoneDv          ", d.mfoneDv);
        console2.log("mfoneRv          ", d.mfoneRv);
        console2.log("mglobalDv        ", d.mglobalDv);
        console2.log("mglobalRv        ", d.mglobalRv);
    }
}
