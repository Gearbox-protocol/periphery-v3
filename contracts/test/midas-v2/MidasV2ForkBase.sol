// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DepositVault} from "midas/DepositVault.sol";
import {RedemptionVault} from "midas/RedemptionVault.sol";
import {DataFeed} from "midas/feeds/DataFeed.sol";
import {MidasAccessControl} from "midas/access/MidasAccessControl.sol";

import {MidasV2Deployer} from "./MidasV2Deployer.sol";

interface IMidasLiveAccessControl {
    function grantRole(bytes32 role, address account) external;
}

/// @notice Test harness: forks mainnet, then deploys via shared MidasV2Deployer.
abstract contract MidasV2ForkBase is Test {
    uint256 internal constant ONE_HUNDRED_PERCENT = 10_000;
    uint256 internal constant MAX_INSTANT_SHARE_MFONE_DV = ONE_HUNDRED_PERCENT;
    uint256 internal constant MAX_INSTANT_SHARE_MFONE_RV = 0;
    uint256 internal constant MAX_INSTANT_SHARE_MGLOBAL = 9_300;
    uint256 internal constant DEPOSIT_USDC_BASE18 = 10_000e18;
    uint256 internal constant DEPOSIT_USDC_RAW = 10_000e6;

    address internal constant DEFAULT_ADMIN = 0xd4195CF4df289a4748C1A7B6dDBE770e27bA1227;
    address internal constant LIVE_AC = 0x0312A9D1Ff2372DDEdCBB21e4B6389aFc919aC4B;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MFONE = 0x238a700eD6165261Cf8b2e544ba797BC11e466Ba;
    address internal constant MGLOBAL = 0x7433806912Eae67919e66aea853d46Fa0aef98A8;

    bytes32 internal constant MFONE_GREENLISTED_ROLE = keccak256("GREENLISTED_ROLE");
    bytes32 internal constant MGLOBAL_GREENLISTED_ROLE = keccak256("M_GLOBAL_GREENLISTED_ROLE");

    MidasAccessControl internal forkAc;
    DataFeed internal mglobalFeed;
    address internal requestRedeemer;
    address internal user;

    DepositVault internal mfoneDv;
    RedemptionVault internal mfoneRv;
    DepositVault internal mglobalDv;
    RedemptionVault internal mglobalRv;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        MidasV2Deployer.Deployment memory d = (new MidasV2Deployer()).deploy();

        forkAc = MidasAccessControl(d.accessControl);
        mglobalFeed = DataFeed(d.mglobalFeed);
        requestRedeemer = d.requestRedeemer;
        mfoneDv = DepositVault(d.mfoneDv);
        mfoneRv = RedemptionVault(d.mfoneRv);
        mglobalDv = DepositVault(d.mglobalDv);
        mglobalRv = RedemptionVault(d.mglobalRv);

        user = makeAddr("user");
        _setupTestUser(user);
    }

    function _setupTestUser(address account) internal {
        deal(USDC, account, DEPOSIT_USDC_RAW);

        vm.startPrank(DEFAULT_ADMIN);
        forkAc.grantRole(MGLOBAL_GREENLISTED_ROLE, account);
        forkAc.grantRole(MFONE_GREENLISTED_ROLE, account);
        IMidasLiveAccessControl(LIVE_AC).grantRole(MFONE_GREENLISTED_ROLE, account);
        IMidasLiveAccessControl(LIVE_AC).grantRole(MGLOBAL_GREENLISTED_ROLE, account);
        vm.stopPrank();
    }

    function _approveUsdc(address vault, uint256 amount) internal {
        vm.prank(user);
        IERC20(USDC).approve(vault, amount);
    }

    function _approveMToken(address token, address vault, uint256 amount) internal {
        vm.prank(user);
        IERC20(token).approve(vault, amount);
    }
}
