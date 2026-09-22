// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Test} from "forge-std/Test.sol";
import {WithdrawalCompressor} from "../../compressors/WithdrawalCompressor.sol";
import {
    MellowWithdrawalSubcompressor
} from "../../compressors/subcompressors/withdrawal/MellowWithdrawalSubcompressor.sol";
import {
    MidasWithdrawalSubcompressor
} from "../../compressors/subcompressors/withdrawal/MidasWithdrawalSubcompressor.sol";
import {
    TreehouseWithdrawalSubcompressor
} from "../../compressors/subcompressors/withdrawal/TreehouseWithdrawalSubcompressor.sol";
import {MidasGateway} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasGateway.sol";
import {MidasRedeemer} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasRedeemer.sol";
import {
    MidasRedemptionVaultPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasRedemptionVaultPhantomToken.sol";
import {
    TreehouseRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/TreehouseRedemptionGateway.sol";
import {
    TreehouseRedemptionPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/TreehouseRedemptionPhantomToken.sol";
import {
    SecuritizeRedemptionSubcompressor
} from "../../compressors/subcompressors/withdrawal/SecuritizeRedemptionSubcompressor.sol";
import {
    SecuritizeRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/SecuritizeRedemptionGateway.sol";
import {
    SecuritizeRedemptionPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/SecuritizeRedemptionPhantomToken.sol";
import {
    SecuritizeRedemptionGatewayAdapter
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/SecuritizeRedemptionGatewayAdapter.sol";

import {LiquidationCompressor} from "../../compressors/LiquidationCompressor.sol";
import {
    TreehouseLiquidationSubcompressor
} from "../../compressors/subcompressors/liquidation/TreehouseLiquidationSubcompressor.sol";

import {
    IRedemptionLogger
} from "@gearbox-protocol/integrations-v3/contracts/integrations/common/interfaces/IRedemptionLogger.sol";

import {
    WithdrawalLib,
    WithdrawalOutput,
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal
} from "../../types/WithdrawalInfo.sol";
import {LiquidationData} from "../../types/LiquidationInfo.sol";
import "forge-std/console.sol";

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
}

struct OracleReport {
    uint224 priceD18;
    uint32 timestamp;
    bool isSuspicious;
}

interface IMellowRateOracleExt {
    function reports(address asset) external view returns (uint256);
    function reportAt(address asset, uint256 index) external view returns (OracleReport memory);
    function acceptedAt(address asset, uint256 index) external view returns (uint32);
}

interface IMellowQueueAdmin {
    function handleReport(uint224 priceD18, uint32 timestamp) external;
    function handleBatches(uint256 batches) external returns (uint256);
}

interface IStETH {
    function submit(address referral) external payable;
}

interface IWithdrawalToken {
    function gateway() external view returns (address);
}

interface IGateway {
    function redemptionLogger() external view returns (address);
}

address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

contract WithdrawalCompressorTest is Test {
    using Address for address;

    WithdrawalCompressor public wc;
    MellowWithdrawalSubcompressor public mwsc;
    MidasWithdrawalSubcompressor public midwsc;
    TreehouseWithdrawalSubcompressor public twsc;

    LiquidationCompressor public lc;
    TreehouseLiquidationSubcompressor public tlsc;

    address user;

    function setUp() public {
        user = makeAddr("user");
        address addressProvider = makeAddr("addressProvider");

        wc = new WithdrawalCompressor(address(this), addressProvider);
        mwsc = new MellowWithdrawalSubcompressor();
        midwsc = new MidasWithdrawalSubcompressor();
        twsc = new TreehouseWithdrawalSubcompressor();

        wc.setSubcompressor(address(mwsc));
        wc.setSubcompressor(address(midwsc));
        wc.setSubcompressor(address(twsc));
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MELLOW_WITHDRAWAL", "GLOBAL::MELLOW_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MIDAS_REDEMPTION", "GLOBAL::MIDAS_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::TREEHOUSE_RD", "GLOBAL::TREEHOUSE_WD_SC");

        lc = new LiquidationCompressor(address(this), addressProvider);
        tlsc = new TreehouseLiquidationSubcompressor();

        lc.setSubcompressor(address(tlsc));
        lc.setLiquidatableTypeToCompressorType("PHANTOM_TOKEN::TREEHOUSE_RD", "GLOBAL::TREEHOUSE_LIQ_SC");
    }

    function test_WC_01_testWithdrawals() public {
        address creditManager = vm.envOr("ATTACH_CREDIT_MANAGER", address(0));

        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        vm.prank(user);
        address creditAccount = ICreditFacadeV3(creditFacade).openCreditAccount(user, new MultiCall[](0), 0);

        WithdrawableAsset[] memory withdrawableAssets = wc.getWithdrawableAssets(creditManager);

        for (uint256 i = 0; i < withdrawableAssets.length; i++) {
            address token = withdrawableAssets[i].token;
            address withdrawalToken = withdrawableAssets[i].withdrawalPhantomToken;

            _approveGatewayInLogger(withdrawalToken);

            uint256 amount = 50 * 10 ** IERC20Metadata(token).decimals();
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

    function test_WC_02_testLiquidation() public {
        address creditManager = vm.envOr("ATTACH_CREDIT_MANAGER", address(0));
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        address creditFacade = ICreditManagerV3(creditManager).creditFacade();
        address underlying = ICreditManagerV3(creditManager).underlying();
        address pool = ICreditManagerV3(creditManager).pool();

        vm.prank(user);
        address creditAccount = ICreditFacadeV3(creditFacade).openCreditAccount(user, new MultiCall[](0), 0);

        WithdrawableAsset[] memory withdrawableAssets = wc.getWithdrawableAssets(creditManager);

        for (uint256 i = 0; i < withdrawableAssets.length; i++) {
            address token = withdrawableAssets[i].token;
            address withdrawalToken = withdrawableAssets[i].withdrawalPhantomToken;

            if (IVersion(withdrawalToken).contractType() != "PHANTOM_TOKEN::TREEHOUSE_RD") {
                continue;
            }

            _approveGatewayInLogger(withdrawalToken);

            uint256 amount = 200 * 10 ** IERC20Metadata(token).decimals();
            deal(token, creditAccount, amount);

            RequestableWithdrawal memory requestableWithdrawal =
                wc.getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount);

            vm.prank(user);
            ICreditFacadeV3(creditFacade).multicall(creditAccount, requestableWithdrawal.requestCalls);

            IERC20(withdrawableAssets[i].withdrawalPhantomToken).balanceOf(creditAccount);
            IERC20(withdrawableAssets[i].underlying).balanceOf(creditAccount);

            address gateway = TreehouseRedemptionPhantomToken(withdrawalToken).gateway();
            address treehouseLiquidator = TreehouseRedemptionGateway(gateway).transferMaster();

            {
                uint256 debtAmount = requestableWithdrawal.outputs[0].amount
                    * (ICreditManagerV3(creditManager).liquidationThresholds(token) + 50) / 10000;

                deal(underlying, user, debtAmount * 5);

                vm.startPrank(user);
                IERC20(underlying).transfer(pool, debtAmount * 3);
                IERC20(underlying).approve(treehouseLiquidator, type(uint256).max);
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

            LiquidationData memory liquidationData = lc.getLiquidationData(user, creditAccount, new PriceUpdate[](0));

            vm.prank(user);
            liquidationData.liquidationCall.target.call(liquidationData.liquidationCall.callData);

            TreehouseRedemptionGateway(gateway).pendingRedeemers(creditAccount);
            TreehouseRedemptionGateway(gateway).pendingRedeemers(user);

            _fulfillWithdrawal(user, withdrawableAssets[i].withdrawalPhantomToken, requestableWithdrawal.claimableAt);

            (ClaimableWithdrawal[] memory claimableWithdrawals,) =
                wc.getExternalAccountCurrentWithdrawals(withdrawalToken, user);

            for (uint256 j = 0; j < claimableWithdrawals.length; ++j) {
                address target = claimableWithdrawals[j].claimCalls[0].target;
                bytes memory callData = claimableWithdrawals[j].claimCalls[0].callData;
                vm.prank(user);
                target.call(callData);
            }

            TreehouseRedemptionGateway(gateway).pendingRedeemers(user);
        }
    }

    function _fulfillWithdrawal(address creditAccount, address withdrawalPhantomToken, uint256 claimableAt) public {
        bytes32 cType = IVersion(withdrawalPhantomToken).contractType();

        if (cType == "PHANTOM_TOKEN::MELLOW_WITHDRAWAL") {
            vm.warp(claimableAt + 1);
        } else if (cType == "PHANTOM_TOKEN::MIDAS_REDEMPTION") {
            vm.warp(claimableAt + 1);
            address gateway = MidasRedemptionVaultPhantomToken(withdrawalPhantomToken).gateway();
            address midasRedemptionVault = MidasGateway(gateway).midasRedemptionVault();
            address mTokenDataFeed = IMidasRedemptionVaultExt(midasRedemptionVault).mTokenDataFeed();
            uint256 mTokenRate = IMidasDataFeed(mTokenDataFeed).getDataInBase18();
            address[] memory redeemers = MidasGateway(gateway).pendingRedeemers(creditAccount);
            for (uint256 i = 0; i < redeemers.length; ++i) {
                uint256 requestId = MidasRedeemer(redeemers[i]).requestId();
                vm.prank(0x2ACB4BdCbEf02f81BF713b696Ac26390d7f79A12);
                IMidasRedemptionVaultExt(midasRedemptionVault).safeApproveRequest(requestId, mTokenRate);
            }
        } else if (cType == "PHANTOM_TOKEN::TREEHOUSE_RD") {
            vm.warp(claimableAt + 1);
        }
    }

    function _assetOrETH(address asset, address weth) internal pure returns (address) {
        return asset == weth ? ETH : asset;
    }

    function _approveGatewayInLogger(address withdrawalPhantomToken) public {
        address gateway = IWithdrawalToken(withdrawalPhantomToken).gateway();
        address logger = IGateway(gateway).redemptionLogger();

        address owner = Ownable(logger).owner();
        vm.prank(owner);
        IRedemptionLogger(logger).setGatewayAllowed(gateway, true);
    }
}
