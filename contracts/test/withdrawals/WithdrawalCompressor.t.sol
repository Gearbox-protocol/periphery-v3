// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Test} from "forge-std/Test.sol";
import {WithdrawalCompressor} from "../../compressors/WithdrawalCompressor.sol";
import {
    MellowWithdrawalSubcompressor
} from "../../compressors/subcompressors/withdrawal/MellowWithdrawalSubcompressor.sol";
import {
    InfinifiWithdrawalSubcompressor
} from "../../compressors/subcompressors/withdrawal/InfinifiWithdrawalSubcompressor.sol";
import {
    MidasWithdrawalSubcompressor
} from "../../compressors/subcompressors/withdrawal/MidasWithdrawalSubcompressor.sol";
import {
    UpshiftWithdrawalSubcompressor
} from "../../compressors/subcompressors/withdrawal/UpshiftWithdrawalSubcompressor.sol";
import {MidasGateway} from "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasGateway.sol";
import {MidasRedeemer} from "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasRedeemer.sol";
import {
    MidasRedemptionVaultPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasRedemptionVaultPhantomToken.sol";
import {
    SecuritizeRedemptionSubcompressor
} from "../../compressors/subcompressors/withdrawal/SecuritizeRedemptionSubcompressor.sol";
import {
    SecuritizeRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedemptionGateway.sol";
import {
    SecuritizeRedemptionPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedemptionPhantomToken.sol";
import {
    SecuritizeRedemptionGatewayAdapter
} from "@gearbox-protocol/integrations-v3/contracts/adapters/securitize/SecuritizeRedemptionGatewayAdapter.sol";

import {
    WithdrawalLib,
    WithdrawalOutput,
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal
} from "../../types/WithdrawalInfo.sol";
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

address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

contract WithdrawalCompressorTest is Test {
    using Address for address;

    WithdrawalCompressor public wc;
    MellowWithdrawalSubcompressor public mwsc;
    InfinifiWithdrawalSubcompressor public iusc;
    MidasWithdrawalSubcompressor public midwsc;
    UpshiftWithdrawalSubcompressor public uwsc;

    address user;

    function setUp() public {
        user = makeAddr("user");
        address addressProvider = makeAddr("addressProvider");

        wc = new WithdrawalCompressor(address(this), addressProvider);
        mwsc = new MellowWithdrawalSubcompressor();
        iusc = new InfinifiWithdrawalSubcompressor();
        midwsc = new MidasWithdrawalSubcompressor();
        uwsc = new UpshiftWithdrawalSubcompressor();

        wc.setSubcompressor(address(mwsc));
        wc.setSubcompressor(address(iusc));
        wc.setSubcompressor(address(midwsc));
        wc.setSubcompressor(address(uwsc));
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MELLOW_WITHDRAWAL", "GLOBAL::MELLOW_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::INFINIFI_UNWIND", "GLOBAL::INFINIFI_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MIDAS_REDEMPTION", "GLOBAL::MIDAS_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::UPSHIFT_WITHDRAW", "GLOBAL::UPSHIFT_WD_SC");
    }

    function test_WC_01_testWithdrawals() public {
        vm.warp(1765929360);

        address creditManager = vm.envOr("ATTACH_CREDIT_MANAGER", address(0));

        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        vm.prank(user);
        address creditAccount = ICreditFacadeV3(creditFacade).openCreditAccount(user, new MultiCall[](0), 0);

        WithdrawableAsset[] memory withdrawableAssets = wc.getWithdrawableAssets(creditManager);

        for (uint256 i = 0; i < withdrawableAssets.length; i++) {
            address token = withdrawableAssets[i].token;
            address withdrawalToken = withdrawableAssets[i].withdrawalPhantomToken;
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

            vm.prank(user);
            ICreditFacadeV3(creditFacade).multicall(creditAccount, claimableWithdrawals[0].claimCalls);

            IERC20(withdrawableAssets[i].withdrawalPhantomToken).balanceOf(creditAccount);
            IERC20(withdrawableAssets[i].underlying).balanceOf(creditAccount);
        }
    }

    function _fulfillWithdrawal(address creditAccount, address withdrawalPhantomToken, uint256 claimableAt) public {
        bytes32 cType = IVersion(withdrawalPhantomToken).contractType();

        if (cType == "PHANTOM_TOKEN::MELLOW_WITHDRAWAL") {
            vm.warp(claimableAt + 1);
        } else if (cType == "PHANTOM_TOKEN::INFINIFI_UNWIND") {
            vm.warp(claimableAt + 1);
        } else if (cType == "PHANTOM_TOKEN::UPSHIFT_WITHDRAW") {
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
        }
    }

    function _assetOrETH(address asset, address weth) internal pure returns (address) {
        return asset == weth ? ETH : asset;
    }
}
