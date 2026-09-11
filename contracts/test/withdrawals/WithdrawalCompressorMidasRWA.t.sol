// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {
    ICreditManagerV3,
    CollateralDebtData,
    CollateralCalcTask
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {IPriceFeed} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeed.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {ITumblerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ITumblerV3.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";
import {IAdapter} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IAdapter.sol";

import {VmSafe} from "forge-std/Vm.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Test} from "forge-std/Test.sol";
import {WithdrawalCompressor} from "../../compressors/WithdrawalCompressor.sol";

import {MidasGateway} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasGateway.sol";
import {MidasRedeemer} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasRedeemer.sol";
import {MidasLiquidator} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasLiquidator.sol";
import {
    IMidasGatewayAdapter
} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/interfaces/IMidasGatewayAdapter.sol";
import {
    MidasRedemptionVaultPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasRedemptionVaultPhantomToken.sol";
import {
    MidasWithdrawalSubcompressor
} from "../../compressors/subcompressors/withdrawal/MidasWithdrawalSubcompressor.sol";

import {
    IMidasAccessControl
} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/interfaces/external/IMidasAccessControl.sol";

import {LiquidationCompressor} from "../../compressors/LiquidationCompressor.sol";
import {
    MidasLiquidationSubcompressor
} from "../../compressors/subcompressors/liquidation/MidasLiquidationSubcompressor.sol";

import {
    WithdrawalLib,
    WithdrawalOutput,
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal
} from "../../types/WithdrawalInfo.sol";

import {LiquidationData} from "../../types/LiquidationInfo.sol";

interface IMidasDataFeed {
    function getDataInBase18() external view returns (uint256);
}

interface IMidasRedemptionVaultExt {
    function mTokenDataFeed() external view returns (address);
    function tokensConfig(address token)
        external
        view
        returns (address dataFeed, uint256 fee, uint256 allowance, bool stable);
    function safeApproveRequest(uint256 requestId, uint256 newMTokenRate) external;
    function requestRedeemer() external view returns (address);
}

interface IMidasGatewayExt {
    function greenlistedRole() external view returns (bytes32);
}

interface IMidasAccessControlExt {
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
}

contract WithdrawalCompressorTest is Test {
    using Address for address;

    WithdrawalCompressor public wc;
    MidasWithdrawalSubcompressor public mwsc;

    LiquidationCompressor public lc;
    MidasLiquidationSubcompressor public mls;

    address public midasLiquidator;

    address public creditManager;
    address public creditConfigurator;
    address public creditFacade;
    address public creditAccount;
    address user;

    function setUp() public {
        user = makeAddr("user");
        address addressProvider = makeAddr("addressProvider");
        creditManager = vm.envOr("ATTACH_CREDIT_MANAGER", address(0));
        creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        creditFacade = ICreditManagerV3(creditManager).creditFacade();
        creditAccount = ICreditFacadeV3(creditFacade).openCreditAccount(user, new MultiCall[](0), 0);
        wc = new WithdrawalCompressor(address(this), addressProvider);
        mwsc = new MidasWithdrawalSubcompressor();

        wc.setSubcompressor(address(mwsc));
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MIDAS_REDEMPTION", "GLOBAL::MIDAS_WD_SC");

        lc = new LiquidationCompressor(address(this), addressProvider);
        mls = new MidasLiquidationSubcompressor();

        lc.setSubcompressor(address(mls));
        lc.setLiquidatableTypeToCompressorType("PHANTOM_TOKEN::MIDAS_REDEMPTION", "GLOBAL::MIDAS_LIQ_SC");

        address[] memory allowedAdapters = ICreditConfiguratorV3(creditConfigurator).allowedAdapters();

        for (uint256 i = 0; i < allowedAdapters.length; i++) {
            bytes32 cType = IVersion(allowedAdapters[i]).contractType();
            if (cType == "ADAPTER::MIDAS_GATEWAY") {
                address midasGateway = IAdapter(allowedAdapters[i]).targetContract();
                midasLiquidator = MidasGateway(midasGateway).transferMaster();
                _grantGreenlistAdmin(midasGateway);
                _grantGreenlist(midasGateway, user);
                _grantGreenlist(midasGateway, creditAccount);
            }
        }
    }

    function test_WCM_01_testWithdrawalsMidasRWA() public {
        WithdrawableAsset[] memory withdrawableAssets = wc.getWithdrawableAssets(creditManager);

        for (uint256 i = 0; i < withdrawableAssets.length; i++) {
            address token = withdrawableAssets[i].token;
            address withdrawalToken = withdrawableAssets[i].withdrawalPhantomToken;

            if (IVersion(withdrawalToken).contractType() != "PHANTOM_TOKEN::MIDAS_REDEMPTION") {
                continue;
            }

            uint256 amount = 500000 * 10 ** IERC20Metadata(token).decimals();
            deal(token, creditAccount, amount);

            RequestableWithdrawal memory requestableWithdrawal =
                wc.getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount);

            vm.prank(user);
            ICreditFacadeV3(creditFacade).multicall(creditAccount, requestableWithdrawal.requestCalls);

            IERC20(withdrawableAssets[i].withdrawalPhantomToken).balanceOf(creditAccount);
            IERC20(withdrawableAssets[i].underlying).balanceOf(creditAccount);

            wc.getCurrentWithdrawals(creditAccount);

            _fulfillWithdrawal(
                creditAccount, withdrawableAssets[i].withdrawalPhantomToken, requestableWithdrawal.claimableAt
            );

            (ClaimableWithdrawal[] memory claimableWithdrawals,) = wc.getCurrentWithdrawals(creditAccount);

            for (uint256 j = 0; j < claimableWithdrawals.length; ++j) {
                vm.prank(user);
                ICreditFacadeV3(creditFacade).multicall(creditAccount, claimableWithdrawals[j].claimCalls);
            }

            IERC20(withdrawableAssets[i].withdrawalPhantomToken).balanceOf(creditAccount);
            IERC20(withdrawableAssets[i].underlying).balanceOf(creditAccount);
        }
    }

    function test_WCM_02_testLiquidationMidasRWA() public {
        address underlying = ICreditManagerV3(creditManager).underlying();
        address pool = ICreditManagerV3(creditManager).pool();

        WithdrawableAsset[] memory withdrawableAssets = wc.getWithdrawableAssets(creditManager);

        for (uint256 i = 0; i < withdrawableAssets.length; i++) {
            address token = withdrawableAssets[i].token;
            address withdrawalToken = withdrawableAssets[i].withdrawalPhantomToken;
            uint256 amount = 500000 * 10 ** IERC20Metadata(token).decimals();
            deal(token, creditAccount, amount);

            RequestableWithdrawal memory requestableWithdrawal =
                wc.getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount);

            vm.prank(user);
            ICreditFacadeV3(creditFacade).multicall(creditAccount, requestableWithdrawal.requestCalls);

            IERC20(withdrawableAssets[i].withdrawalPhantomToken).balanceOf(creditAccount);
            IERC20(withdrawableAssets[i].underlying).balanceOf(creditAccount);

            {
                uint256 debtAmount = requestableWithdrawal.outputs[0].amount
                    * (ICreditManagerV3(creditManager).liquidationThresholds(token) + 50) / 10000;

                vm.prank(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341);
                IERC20(withdrawableAssets[i].underlying).transfer(user, debtAmount * 5);

                vm.startPrank(user);
                IERC20(underlying).transfer(pool, debtAmount * 3);
                IERC20(underlying).approve(midasLiquidator, type(uint256).max);
                vm.stopPrank();

                MultiCall[] memory calls = new MultiCall[](2);
                calls[0] = MultiCall({
                    target: creditFacade, callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debtAmount))
                });
                calls[1] = MultiCall({
                    target: creditFacade,
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.updateQuota,
                        (withdrawableAssets[i].withdrawalPhantomToken, int96(uint96(debtAmount * 2)), 0)
                    )
                });

                vm.prank(user);
                ICreditFacadeV3(creditFacade).multicall(creditAccount, calls);

                vm.roll(block.number + 1);

                vm.prank(creditAccount);
                IERC20(underlying).transfer(user, debtAmount);
            }

            {

                address acl = ICreditConfiguratorV3(creditConfigurator).acl();

                address configurator = Ownable(acl).owner();

                vm.prank(configurator);
                ICreditConfiguratorV3(creditConfigurator).setLiquidationThreshold(withdrawalToken, 0);
            }

            address gateway = MidasRedemptionVaultPhantomToken(withdrawalToken).gateway();

            LiquidationData memory liquidationData =
                lc.getLiquidationData(user, creditAccount, new PriceUpdate[](0));

            vm.prank(user);
            liquidationData.liquidationCall.target.call(liquidationData.liquidationCall.callData);

            MidasGateway(gateway).pendingRedeemers(creditAccount);
            MidasGateway(gateway).pendingRedeemers(user);

            _fulfillWithdrawal(user, withdrawableAssets[i].withdrawalPhantomToken, requestableWithdrawal.claimableAt);

            (ClaimableWithdrawal[] memory claimableWithdrawals,) =
                wc.getExternalAccountCurrentWithdrawals(withdrawalToken, user);

            for (uint256 j = 0; j < claimableWithdrawals.length; ++j) {
                address target = claimableWithdrawals[j].claimCalls[0].target;
                bytes memory callData = claimableWithdrawals[j].claimCalls[0].callData;
                vm.prank(user);
                target.call(callData);
            }

            MidasGateway(gateway).pendingRedeemers(user);
        }
    }

    function _fulfillWithdrawal(address forAccount, address withdrawalPhantomToken, uint256 claimableAt) public {
        bytes32 cType = IVersion(withdrawalPhantomToken).contractType();

        if (cType == "PHANTOM_TOKEN::MIDAS_REDEMPTION") {
            vm.warp(block.timestamp + 3600);
            address gateway = MidasRedemptionVaultPhantomToken(withdrawalPhantomToken).gateway();
            address midasRedemptionVault = MidasGateway(gateway).midasRedemptionVault();
            address mTokenDataFeed = IMidasRedemptionVaultExt(midasRedemptionVault).mTokenDataFeed();
            uint256 mTokenRate = IMidasDataFeed(mTokenDataFeed).getDataInBase18();
            address tokenOut = MidasRedemptionVaultPhantomToken(withdrawalPhantomToken).underlying();
            address[] memory redeemers = MidasGateway(gateway).pendingRedeemers(forAccount);
            for (uint256 i = 0; i < redeemers.length; ++i) {
                address requestRedeemer = IMidasRedemptionVaultExt(midasRedemptionVault).requestRedeemer();

                vm.startPrank(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341);
                IERC20(tokenOut).transfer(requestRedeemer, 1_000_000 * 10 ** IERC20Metadata(tokenOut).decimals());
                vm.stopPrank();

                uint256 requestId = MidasRedeemer(redeemers[i]).requestId();
                vm.prank(0x2ACB4BdCbEf02f81BF713b696Ac26390d7f79A12);
                IMidasRedemptionVaultExt(midasRedemptionVault).safeApproveRequest(requestId, mTokenRate);
            }
        }
    }

    function _grantGreenlistAdmin(address midasGateway) internal {
        address accessControl = MidasGateway(midasGateway).accessControl();
        if (accessControl == address(0)) {
            return;
        }
        address admin = vm.envOr("MIDAS_ACL_ADMIN", address(0));
        if (admin == address(0)) {
            emit log_string("<WARNING>: MIDAS_ACL_ADMIN not set, skipping test:");
            return;
        }
        bytes32 greenlistedRole = IMidasGatewayExt(midasGateway).greenlistedRole();
        bytes32 greenlistOperatorRole = IMidasAccessControlExt(accessControl).getRoleAdmin(greenlistedRole);
        vm.prank(admin);
        IMidasAccessControl(accessControl).grantRole(greenlistOperatorRole, midasGateway);
    }

    function _grantGreenlist(address midasGateway, address _user) internal {
        address accessControl = MidasGateway(midasGateway).accessControl();
        if (accessControl == address(0)) {
            return;
        }
        address admin = vm.envOr("MIDAS_ACL_ADMIN", address(0));
        if (admin == address(0)) {
            emit log_string("<WARNING>: MIDAS_ACL_ADMIN not set, skipping test:");
            return;
        }

        bytes32 greenlistedRole = IMidasGatewayExt(midasGateway).greenlistedRole();
        bytes32 greenlistOperatorRole = IMidasAccessControlExt(accessControl).getRoleAdmin(greenlistedRole);

        vm.prank(admin);
        IMidasAccessControl(accessControl).grantRole(greenlistOperatorRole, admin);
        vm.prank(admin);
        IMidasAccessControl(accessControl).grantRole(greenlistedRole, _user);
    }
}
