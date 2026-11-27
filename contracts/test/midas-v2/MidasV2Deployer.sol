// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ScriptBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {DepositVault} from "midas/DepositVault.sol";
import {RedemptionVault} from "midas/RedemptionVault.sol";
import {DataFeed} from "midas/feeds/DataFeed.sol";
import {MidasAccessControl} from "midas/access/MidasAccessControl.sol";
import {MidasPauseManager} from "midas/access/MidasPauseManager.sol";
import {MidasTimelockManager} from "midas/access/MidasTimelockManager.sol";
import {CommonVaultInitParams} from "midas/interfaces/IManageableVault.sol";
import {DepositVaultInitParams} from "midas/interfaces/IDepositVault.sol";
import {RedemptionVaultInitParams} from "midas/interfaces/IRedemptionVault.sol";

interface IMidasLiveAccessControl {
    function grantRole(bytes32 role, address account) external;
}

/// @notice Shared midas v2 fork deployment (plain DV/RV for mfONE + mGLOBAL).
/// @dev Intended for an already-running mainnet fork (Anvil). Uses cheatcodes for
///      live-AC grants, funding, and maxSupplyCap mocks.
contract MidasV2Deployer is ScriptBase, StdCheats {
    uint256 public constant ONE_HUNDRED_PERCENT = 10_000;
    uint256 public constant MAX_INSTANT_SHARE_MFONE_DV = ONE_HUNDRED_PERCENT;
    uint256 public constant MAX_INSTANT_SHARE_MFONE_RV = 0;
    uint256 public constant MAX_INSTANT_SHARE_MGLOBAL = 9_300; // 93% (7% holdback)
    uint256 public constant REDEMPTION_LIQUIDITY_USDC = 10_000_000e6;

    address public constant DEFAULT_ADMIN = 0xd4195CF4df289a4748C1A7B6dDBE770e27bA1227;
    address public constant LIVE_AC = 0x0312A9D1Ff2372DDEdCBB21e4B6389aFc919aC4B;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDC_FEED = 0x3aAc6fd73fA4e16Ec683BD4aaF5Ec89bb2C0EdC2;

    address public constant MFONE = 0x238a700eD6165261Cf8b2e544ba797BC11e466Ba;
    address public constant MFONE_FEED = 0xCF4e49f5e750Af8F2f9Aa1642B68E5839D9c1C00;
    address public constant MFONE_TOKENS_RECEIVER = 0x86B16681E21E857A9a71a8FDfC33AB1eB8213b74;

    address public constant MGLOBAL = 0x7433806912Eae67919e66aea853d46Fa0aef98A8;
    /// @dev Unadjusted mGLOBAL/USD aggregator (live DV/RV feeds apply ±7% holdback factors on top).
    address public constant MGLOBAL_UNDERLYING_AGGREGATOR = 0x66Aa9fcD63DF74e1f67A9452E6E59Fbc67f75E38;
    address public constant MGLOBAL_DV_RECEIVER = 0xf5Ca9DcbabecDd95A5b7b091A2a70b81ddFa4184;
    address public constant MGLOBAL_RV_RECEIVER = 0xb38c71199d7B480A8FEBaDEEff59e5516338bcf6;

    bytes32 public constant MFONE_MINT_ROLE = keccak256("M_FONE_MINT_OPERATOR_ROLE");
    bytes32 public constant MFONE_BURN_ROLE = keccak256("M_FONE_BURN_OPERATOR_ROLE");
    bytes32 public constant MFONE_DV_ADMIN_ROLE = keccak256("M_FONE_DEPOSIT_VAULT_ADMIN_ROLE");
    bytes32 public constant MFONE_RV_ADMIN_ROLE = keccak256("M_FONE_REDEMPTION_VAULT_ADMIN_ROLE");
    bytes32 public constant MFONE_GREENLISTED_ROLE = keccak256("GREENLISTED_ROLE");
    bytes32 public constant MFONE_GREENLIST_OPERATOR_ROLE = keccak256("GREENLIST_OPERATOR_ROLE");

    bytes32 public constant MGLOBAL_MINT_ROLE = keccak256("M_GLOBAL_MINT_OPERATOR_ROLE");
    bytes32 public constant MGLOBAL_BURN_ROLE = keccak256("M_GLOBAL_BURN_OPERATOR_ROLE");
    bytes32 public constant MGLOBAL_DV_ADMIN_ROLE = keccak256("M_GLOBAL_DEPOSIT_VAULT_ADMIN_ROLE");
    bytes32 public constant MGLOBAL_RV_ADMIN_ROLE = keccak256("M_GLOBAL_REDEMPTION_VAULT_ADMIN_ROLE");
    bytes32 public constant MGLOBAL_GREENLISTED_ROLE = keccak256("M_GLOBAL_GREENLISTED_ROLE");
    bytes32 public constant MGLOBAL_FEED_ADMIN_ROLE = keccak256("M_GLOBAL_DATA_FEED_ADMIN_ROLE");

    struct Deployment {
        address proxyAdmin;
        address accessControl;
        address pauseManager;
        address timelockManager;
        address mglobalFeed;
        address requestRedeemer;
        address mfoneDv;
        address mfoneRv;
        address mglobalDv;
        address mglobalRv;
    }

    /// @notice Deploy the full midas v2 fork stack and wire live mint/burn roles.
    /// @dev Creates a fresh pre-funded `requestRedeemer` (no env). Does not set up a user.
    function deploy() public returns (Deployment memory d) {
        d.requestRedeemer = makeAddr("requestRedeemer");

        // Live mTokens predate maxSupplyCap(); new DepositVault requires it.
        vm.mockCall(MFONE, abi.encodeWithSignature("maxSupplyCap()"), abi.encode(type(uint256).max));
        vm.mockCall(MGLOBAL, abi.encodeWithSignature("maxSupplyCap()"), abi.encode(type(uint256).max));

        d.proxyAdmin = address(new ProxyAdmin());

        (d.accessControl, d.pauseManager, d.timelockManager) =
            _deployAccessStack(d.proxyAdmin, d.requestRedeemer);
        d.mglobalFeed = _deployMGlobalDataFeed(d.proxyAdmin, d.accessControl);

        d.mfoneDv = _deployDepositVault(
            d.proxyAdmin,
            d.accessControl,
            MFONE_DV_ADMIN_ROLE,
            MFONE_GREENLISTED_ROLE,
            MFONE,
            MFONE_FEED,
            MFONE_TOKENS_RECEIVER,
            0,
            10,
            MAX_INSTANT_SHARE_MFONE_DV
        );
        d.mfoneRv = _deployRedemptionVault(
            d.proxyAdmin,
            d.accessControl,
            d.requestRedeemer,
            MFONE_RV_ADMIN_ROLE,
            MFONE_GREENLISTED_ROLE,
            MFONE,
            MFONE_FEED,
            MFONE_TOKENS_RECEIVER,
            1e18,
            100,
            MAX_INSTANT_SHARE_MFONE_RV
        );
        d.mglobalDv = _deployDepositVault(
            d.proxyAdmin,
            d.accessControl,
            MGLOBAL_DV_ADMIN_ROLE,
            MGLOBAL_GREENLISTED_ROLE,
            MGLOBAL,
            d.mglobalFeed,
            MGLOBAL_DV_RECEIVER,
            1e18,
            0,
            MAX_INSTANT_SHARE_MGLOBAL
        );
        d.mglobalRv = _deployRedemptionVault(
            d.proxyAdmin,
            d.accessControl,
            d.requestRedeemer,
            MGLOBAL_RV_ADMIN_ROLE,
            MGLOBAL_GREENLISTED_ROLE,
            MGLOBAL,
            d.mglobalFeed,
            MGLOBAL_RV_RECEIVER,
            1e18,
            50,
            MAX_INSTANT_SHARE_MGLOBAL
        );

        _grantLiveRoles(d.requestRedeemer, d.mfoneDv, d.mfoneRv, d.mglobalDv, d.mglobalRv);
        _configureVaults(d.mfoneDv, d.mfoneRv, d.mglobalDv, d.mglobalRv);
        _fundActors(d.requestRedeemer, d.mfoneRv, d.mglobalRv);
    }

    function _deployAccessStack(address proxyAdmin, address requestRedeemer)
        private
        returns (address acAddr, address pauseManagerAddr, address timelockManagerAddr)
    {
        bytes32[] memory userFacingRoles = new bytes32[](1);
        userFacingRoles[0] = MGLOBAL_GREENLISTED_ROLE;

        // This contract is msg.sender on proxy construction → receives DEFAULT_ADMIN.
        MidasAccessControl ac = MidasAccessControl(
            _deployProxy(
                proxyAdmin,
                address(new MidasAccessControl()),
                abi.encodeCall(MidasAccessControl.initialize, (0, userFacingRoles))
            )
        );

        MidasPauseManager pauseManager = MidasPauseManager(
            _deployProxy(
                proxyAdmin,
                address(new MidasPauseManager()),
                abi.encodeCall(MidasPauseManager.initialize, (address(ac), uint32(0), uint32(0)))
            )
        );

        address[] memory council = new address[](5);
        council[0] = address(uint160(uint256(keccak256("midas-v2-council0"))));
        council[1] = address(uint160(uint256(keccak256("midas-v2-council1"))));
        council[2] = address(uint160(uint256(keccak256("midas-v2-council2"))));
        council[3] = address(uint160(uint256(keccak256("midas-v2-council3"))));
        council[4] = address(uint160(uint256(keccak256("midas-v2-council4"))));

        MidasTimelockManager timelockManager = MidasTimelockManager(
            _deployProxy(
                proxyAdmin,
                address(new MidasTimelockManager()),
                abi.encodeCall(MidasTimelockManager.initialize, (address(ac), 10, council))
            )
        );

        ac.initializeRelationships(address(timelockManager), address(pauseManager));
        timelockManager.initializeTimelock(address(1)); // unused with defaultDelay=0

        ac.grantRole(bytes32(0), DEFAULT_ADMIN);
        ac.grantRole(MFONE_GREENLIST_OPERATOR_ROLE, DEFAULT_ADMIN);
        ac.grantRole(MFONE_DV_ADMIN_ROLE, DEFAULT_ADMIN);
        ac.grantRole(MFONE_RV_ADMIN_ROLE, DEFAULT_ADMIN);
        ac.grantRole(MGLOBAL_DV_ADMIN_ROLE, DEFAULT_ADMIN);
        ac.grantRole(MGLOBAL_RV_ADMIN_ROLE, DEFAULT_ADMIN);
        ac.grantRole(MGLOBAL_FEED_ADMIN_ROLE, DEFAULT_ADMIN);
        ac.grantRole(MGLOBAL_GREENLISTED_ROLE, requestRedeemer);

        vm.startPrank(DEFAULT_ADMIN);
        ac.grantRole(MFONE_GREENLISTED_ROLE, requestRedeemer);
        vm.stopPrank();

        return (address(ac), address(pauseManager), address(timelockManager));
    }

    function _deployMGlobalDataFeed(address proxyAdmin, address ac) private returns (address) {
        bytes memory initData = abi.encodeCall(
            DataFeed.initialize,
            (
                ac,
                MGLOBAL_UNDERLYING_AGGREGATOR,
                5_184_000, // 60 days, same as live adjusted feeds
                int256(90_000_000), // $0.90
                int256(130_000_000), // $1.30
                address(0) // no L2 sequencer check on mainnet
            )
        );
        return _deployProxy(proxyAdmin, address(new DataFeed(MGLOBAL_FEED_ADMIN_ROLE)), initData);
    }

    function _grantLiveRoles(
        address requestRedeemer,
        address mfoneDv,
        address mfoneRv,
        address mglobalDv,
        address mglobalRv
    ) private {
        vm.startPrank(DEFAULT_ADMIN);
        IMidasLiveAccessControl(LIVE_AC).grantRole(MFONE_GREENLIST_OPERATOR_ROLE, DEFAULT_ADMIN);
        IMidasLiveAccessControl(LIVE_AC).grantRole(MFONE_GREENLISTED_ROLE, requestRedeemer);
        IMidasLiveAccessControl(LIVE_AC).grantRole(MGLOBAL_GREENLISTED_ROLE, requestRedeemer);
        IMidasLiveAccessControl(LIVE_AC).grantRole(MFONE_MINT_ROLE, mfoneDv);
        IMidasLiveAccessControl(LIVE_AC).grantRole(MFONE_BURN_ROLE, mfoneRv);
        IMidasLiveAccessControl(LIVE_AC).grantRole(MGLOBAL_MINT_ROLE, mglobalDv);
        IMidasLiveAccessControl(LIVE_AC).grantRole(MGLOBAL_BURN_ROLE, mglobalRv);
        vm.stopPrank();
    }

    function _configureVaults(address mfoneDv, address mfoneRv, address mglobalDv, address mglobalRv)
        private
    {
        vm.startPrank(DEFAULT_ADMIN);
        _addUsdcAndLimits(mfoneDv);
        _addUsdcAndLimits(mfoneRv);
        _addUsdcAndLimits(mglobalDv);
        _addUsdcAndLimits(mglobalRv);
        DepositVault(mfoneDv).setGreenlistEnable(true);
        RedemptionVault(mfoneRv).setGreenlistEnable(true);
        DepositVault(mglobalDv).setGreenlistEnable(true);
        RedemptionVault(mglobalRv).setGreenlistEnable(true);
        vm.stopPrank();
    }

    function _addUsdcAndLimits(address vault) private {
        DepositVault(vault).addPaymentToken(USDC, USDC_FEED, 0, type(uint256).max, true);
        DepositVault(vault).setInstantLimitConfig(1 days, type(uint128).max);
    }

    function _fundActors(address requestRedeemer, address mfoneRv, address mglobalRv) private {
        deal(USDC, mfoneRv, REDEMPTION_LIQUIDITY_USDC);
        deal(USDC, mglobalRv, REDEMPTION_LIQUIDITY_USDC);
        deal(USDC, requestRedeemer, REDEMPTION_LIQUIDITY_USDC);

        vm.startPrank(requestRedeemer);
        IERC20(USDC).approve(mfoneRv, type(uint256).max);
        IERC20(USDC).approve(mglobalRv, type(uint256).max);
        vm.stopPrank();
    }

    function _deployDepositVault(
        address proxyAdmin,
        address ac,
        bytes32 adminRole,
        bytes32 greenlistedRole,
        address mToken,
        address mTokenFeed,
        address tokensReceiver,
        uint256 minAmount,
        uint256 instantFee,
        uint256 maxInstantShare
    ) private returns (address) {
        CommonVaultInitParams memory common = _commonParams(
            ac, mToken, mTokenFeed, tokensReceiver, minAmount, instantFee, maxInstantShare
        );
        DepositVaultInitParams memory dvParams = DepositVaultInitParams({
            minMTokenAmountForFirstDeposit: 0,
            maxAmountPerRequest: type(uint256).max
        });
        return _deployProxy(
            proxyAdmin,
            address(new DepositVault(adminRole, greenlistedRole)),
            abi.encodeCall(DepositVault.initialize, (common, dvParams))
        );
    }

    function _deployRedemptionVault(
        address proxyAdmin,
        address ac,
        address requestRedeemer,
        bytes32 adminRole,
        bytes32 greenlistedRole,
        address mToken,
        address mTokenFeed,
        address tokensReceiver,
        uint256 minAmount,
        uint256 instantFee,
        uint256 maxInstantShare
    ) private returns (address) {
        CommonVaultInitParams memory common = _commonParams(
            ac, mToken, mTokenFeed, tokensReceiver, minAmount, instantFee, maxInstantShare
        );
        RedemptionVaultInitParams memory rvParams = RedemptionVaultInitParams({
            requestRedeemer: requestRedeemer,
            loanLp: address(0),
            loanRepaymentAddress: address(0),
            loanSwapperVault: address(0),
            loanApr: 0
        });
        return _deployProxy(
            proxyAdmin,
            address(new RedemptionVault(adminRole, greenlistedRole)),
            abi.encodeCall(RedemptionVault.initialize, (common, rvParams))
        );
    }

    function _commonParams(
        address ac,
        address mToken,
        address mTokenFeed,
        address tokensReceiver,
        uint256 minAmount,
        uint256 instantFee,
        uint256 maxInstantShare
    ) private pure returns (CommonVaultInitParams memory) {
        return CommonVaultInitParams({
            variationTolerance: 900,
            minAmount: minAmount,
            instantFee: instantFee,
            ac: ac,
            sanctionsList: address(0),
            mToken: mToken,
            mTokenDataFeed: mTokenFeed,
            tokensReceiver: tokensReceiver,
            minInstantFee: 0,
            maxInstantFee: ONE_HUNDRED_PERCENT,
            maxInstantShare: maxInstantShare,
            maxApproveRequestId: type(uint256).max,
            sequentialRequestProcessing: false
        });
    }

    function _deployProxy(address proxyAdmin, address impl, bytes memory initData)
        private
        returns (address)
    {
        return address(new TransparentUpgradeableProxy(impl, proxyAdmin, initData));
    }
}
