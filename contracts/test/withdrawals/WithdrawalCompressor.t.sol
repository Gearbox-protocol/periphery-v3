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
import {MellowWithdrawalSubcompressor} from
    "../../compressors/subcompressors/withdrawal/MellowWithdrawalSubcompressor.sol";
import {InfinifiWithdrawalSubcompressor} from
    "../../compressors/subcompressors/withdrawal/InfinifiWithdrawalSubcompressor.sol";
import {MidasWithdrawalSubcompressor} from
    "../../compressors/subcompressors/withdrawal/MidasWithdrawalSubcompressor.sol";
import {UpshiftWithdrawalSubcompressor} from
    "../../compressors/subcompressors/withdrawal/UpshiftWithdrawalSubcompressor.sol";
import {MidasRedemptionVaultGateway} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasRedemptionVaultGateway.sol";
import {MidasRedemptionVaultPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasRedemptionVaultPhantomToken.sol";
import {KelpLRTWithdrawalSubcompressor} from
    "../../compressors/subcompressors/withdrawal/KelpLRTWithdrawalSubcompressor.sol";
import {IKelpLRTWithdrawalManager} from
    "@gearbox-protocol/integrations-v3/contracts/integrations/kelp/IKelpLRTWithdrawalManager.sol";
import {IKelpLRTWithdrawalManagerGateway} from
    "@gearbox-protocol/integrations-v3/contracts/interfaces/kelp/IKelpLRTWithdrawalManagerGateway.sol";
import {KelpLRTWithdrawalPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/kelp/KelpLRTWithdrawalPhantomToken.sol";

// import {MellowFlexibleDepositSubcompressor} from
//     "../../compressors/subcompressors/withdrawal/MellowFlexibleDepositSubcompressor.sol";
// import {MellowFlexibleRedeemSubcompressor} from
//     "../../compressors/subcompressors/withdrawal/MellowFlexibleRedeemSubcompressor.sol";
// import {MellowFlexibleDepositPhantomToken} from
//     "@gearbox-protocol/integrations-v3/contracts/helpers/mellow/MellowFlexibleDepositPhantomToken.sol";
// import {IMellowFlexibleDepositGateway} from
//     "@gearbox-protocol/integrations-v3/contracts/interfaces/mellow/IMellowFlexibleDepositGateway.sol";
// import {IMellowDepositQueue} from
//     "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowDepositQueue.sol";
// import {IMellowRateOracle} from "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowRateOracle.sol";
// import {MellowFlexibleRedeemPhantomToken} from
//     "@gearbox-protocol/integrations-v3/contracts/helpers/mellow/MellowFlexibleRedeemPhantomToken.sol";
// import {IMellowFlexibleRedeemGateway} from
//     "@gearbox-protocol/integrations-v3/contracts/interfaces/mellow/IMellowFlexibleRedeemGateway.sol";
// import {IMellowRedeemQueue} from
//     "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowRedeemQueue.sol";
// import {IMellowRateOracle} from "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowRateOracle.sol";

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

interface IKelpLRTWithdrawalManagerAdmin {
    function unlockQueue(
        address asset,
        uint256 firstExcludedIndex,
        uint256 minimumAssetPrice,
        uint256 minimumRsEthPrice,
        uint256 maximumAssetPrice,
        uint256 maximumRsEthPrice
    ) external;
    function lrtConfig() external view returns (address);
}

interface IKelpLRTConfig {
    function getContract(bytes32 cType) external view returns (address);
}

interface IKelpLRTOracle {
    function rsETHPrice() external view returns (uint256);
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IKelpGatewayExt {
    function weth() external view returns (address);
}

interface IStETH {
    function submit(address referral) external payable;
}

address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

bytes32 constant KELP_LRT_ORACLE = keccak256("LRT_ORACLE");
bytes32 constant KELP_LRT_UNSTAKING_VAULT = keccak256("LRT_UNSTAKING_VAULT");

contract WithdrawalCompressorTest is Test {
    using Address for address;

    WithdrawalCompressor public wc;
    MellowWithdrawalSubcompressor public mwsc;
    InfinifiWithdrawalSubcompressor public iusc;
    MidasWithdrawalSubcompressor public midwsc;
    UpshiftWithdrawalSubcompressor public uwsc;
    KelpLRTWithdrawalSubcompressor public klrtwsc;
    // MellowFlexibleDepositSubcompressor public mfdsc;
    // MellowFlexibleRedeemSubcompressor public mfrsc;

    address user;

    function setUp() public {
        user = makeAddr("user");
        address addressProvider = makeAddr("addressProvider");

        wc = new WithdrawalCompressor(address(this), addressProvider);
        mwsc = new MellowWithdrawalSubcompressor();
        iusc = new InfinifiWithdrawalSubcompressor();
        midwsc = new MidasWithdrawalSubcompressor();
        uwsc = new UpshiftWithdrawalSubcompressor();
        klrtwsc = new KelpLRTWithdrawalSubcompressor();
        // mfdsc = new MellowFlexibleDepositSubcompressor();
        // mfrsc = new MellowFlexibleRedeemSubcompressor();

        wc.setSubcompressor(address(mwsc));
        wc.setSubcompressor(address(iusc));
        wc.setSubcompressor(address(midwsc));
        wc.setSubcompressor(address(uwsc));
        wc.setSubcompressor(address(klrtwsc));
        // wc.setSubcompressor(address(mfdsc));
        // wc.setSubcompressor(address(mfrsc));
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MELLOW_WITHDRAWAL", "GLOBAL::MELLOW_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::INFINIFI_UNWIND", "GLOBAL::INFINIFI_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MIDAS_REDEMPTION", "GLOBAL::MIDAS_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::UPSHIFT_WITHDRAW", "GLOBAL::UPSHIFT_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::KELP_WITHDRAWAL", "GLOBAL::KELP_LRT_WD_SC");
        // wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MELLOW_DEPOSIT", "GLOBAL::MELF_DEPOSIT_WD_SC");
        // wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MELLOW_REDEEM", "GLOBAL::MELF_REDEEM_WD_SC");
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
        } else if (cType == "PHANTOM_TOKEN::KELP_WITHDRAWAL") {
            vm.warp(claimableAt + 1);
            address gateway = KelpLRTWithdrawalPhantomToken(withdrawalPhantomToken).withdrawalManagerGateway();
            address withdrawalManager = IKelpLRTWithdrawalManagerGateway(gateway).withdrawalManager();
            address lrtConfig = IKelpLRTWithdrawalManagerAdmin(withdrawalManager).lrtConfig();
            address lrtOracle = IKelpLRTConfig(lrtConfig).getContract(KELP_LRT_ORACLE);
            address lrtUnstakingVault = IKelpLRTConfig(lrtConfig).getContract(KELP_LRT_UNSTAKING_VAULT);
            address asset = KelpLRTWithdrawalPhantomToken(withdrawalPhantomToken).tokenOut();
            address weth = IKelpGatewayExt(gateway).weth();
            address withdrawer = IKelpLRTWithdrawalManagerGateway(gateway).accountToWithdrawer(creditAccount);

            if (_assetOrETH(asset, weth) == ETH) {
                vm.deal(lrtUnstakingVault, 100000000 ether);
            } else if (asset == STETH) {
                vm.deal(address(this), 10000 ether);
                IStETH(STETH).submit{value: 10000 ether}(address(0));
                IERC20(STETH).transfer(lrtUnstakingVault, IERC20(STETH).balanceOf(address(this)));
            } else {
                deal(asset, lrtUnstakingVault, 100000000 ether);
            }

            uint256 assetPrice = IKelpLRTOracle(lrtOracle).getAssetPrice(_assetOrETH(asset, weth));
            uint256 rsETHPrice = IKelpLRTOracle(lrtOracle).rsETHPrice();

            (,,, uint256 userNonce) = IKelpLRTWithdrawalManager(withdrawalManager).getUserWithdrawalRequest(
                _assetOrETH(asset, weth), withdrawer, 0
            );

            vm.prank(0xF2099c4783921f44Ac988B67e743DAeFd4A00efd);
            IKelpLRTWithdrawalManagerAdmin(withdrawalManager).unlockQueue(
                _assetOrETH(asset, weth), userNonce + 1, assetPrice, rsETHPrice, assetPrice, rsETHPrice
            );
        } else if (cType == "PHANTOM_TOKEN::MIDAS_REDEMPTION") {
            vm.warp(claimableAt + 1);
            address gateway = MidasRedemptionVaultPhantomToken(withdrawalPhantomToken).gateway();
            address midasRedemptionVault = MidasRedemptionVaultGateway(gateway).midasRedemptionVault();
            (,, uint256 requestId,,) = MidasRedemptionVaultGateway(gateway).pendingRedemptions(creditAccount);
            address mTokenDataFeed = IMidasRedemptionVaultExt(midasRedemptionVault).mTokenDataFeed();
            uint256 mTokenRate = IMidasDataFeed(mTokenDataFeed).getDataInBase18();

            vm.prank(0x2ACB4BdCbEf02f81BF713b696Ac26390d7f79A12);
            IMidasRedemptionVaultExt(midasRedemptionVault).safeApproveRequest(requestId, mTokenRate);
        }
        // } else if (cType == "PHANTOM_TOKEN::MELLOW_DEPOSIT") {
        //     vm.warp(claimableAt + 1);

        //     address depositQueueGateway =
        //         MellowFlexibleDepositPhantomToken(withdrawalPhantomToken).depositQueueGateway();
        //     address depositQueue = IMellowFlexibleDepositGateway(depositQueueGateway).mellowDepositQueue();
        //     address vault = IMellowDepositQueue(depositQueue).vault();
        //     address mellowRateOracle = MellowFlexibleDepositPhantomToken(withdrawalPhantomToken).mellowRateOracle();
        //     address asset = IMellowFlexibleDepositGateway(depositQueueGateway).asset();

        //     uint256 reportNum = IMellowRateOracleExt(mellowRateOracle).reports(asset);
        //     OracleReport memory report = IMellowRateOracleExt(mellowRateOracle).reportAt(asset, reportNum - 1);

        //     vm.prank(vault);
        //     IMellowQueueAdmin(depositQueue).handleReport(report.priceD18, uint32(block.timestamp - 1));
        // } else if (cType == "PHANTOM_TOKEN::MELLOW_REDEEM") {
        //     vm.warp(claimableAt + 1);

        //     address redeemQueueGateway = MellowFlexibleRedeemPhantomToken(withdrawalPhantomToken).redeemQueueGateway();
        //     address redeemQueue = IMellowFlexibleRedeemGateway(redeemQueueGateway).mellowRedeemQueue();
        //     address vault = IMellowRedeemQueue(redeemQueue).vault();
        //     address mellowRateOracle = MellowFlexibleRedeemPhantomToken(withdrawalPhantomToken).mellowRateOracle();
        //     address asset = IMellowFlexibleRedeemGateway(redeemQueueGateway).asset();

        //     uint256 reportNum = IMellowRateOracleExt(mellowRateOracle).reports(asset);
        //     OracleReport memory report = IMellowRateOracleExt(mellowRateOracle).reportAt(asset, reportNum - 1);

        //     vm.prank(vault);
        //     IMellowQueueAdmin(redeemQueue).handleReport(report.priceD18, uint32(block.timestamp - 1));
        //     IMellowQueueAdmin(redeemQueue).handleBatches(1000);
        // }
    }

    function _assetOrETH(address asset, address weth) internal pure returns (address) {
        return asset == weth ? ETH : asset;
    }
}
