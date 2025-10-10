// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

import {MidasRedemptionVaultGateway} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasRedemptionVaultGateway.sol";
import {MidasRedemptionVaultPhantomToken} from
    "@gearbox-protocol/integrations-v3/contracts/helpers/midas/MidasRedemptionVaultPhantomToken.sol";

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

contract WithdrawalCompressorTest is Test {
    using Address for address;

    WithdrawalCompressor public wc;
    MellowWithdrawalSubcompressor public mwsc;
    InfinifiWithdrawalSubcompressor public iusc;
    MidasWithdrawalSubcompressor public midwsc;

    address user;

    function setUp() public {
        user = makeAddr("user");
        address addressProvider = makeAddr("addressProvider");

        wc = new WithdrawalCompressor(address(this), addressProvider);
        mwsc = new MellowWithdrawalSubcompressor();
        iusc = new InfinifiWithdrawalSubcompressor();
        midwsc = new MidasWithdrawalSubcompressor();

        wc.setSubcompressor(address(mwsc));
        wc.setSubcompressor(address(iusc));
        wc.setSubcompressor(address(midwsc));
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MELLOW_WITHDRAWAL", "GLOBAL::MELLOW_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::INFINIFI_UNWIND", "GLOBAL::INFINIFI_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MIDAS_REDEMPTION", "GLOBAL::MIDAS_WD_SC");
    }

    function test_WC_01_testWithdrawals() public {
        address creditManager = vm.envOr("ATTACH_CREDIT_MANAGER", address(0));

        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        vm.prank(user);
        address creditAccount = ICreditFacadeV3(creditFacade).openCreditAccount(user, new MultiCall[](0), 0);

        WithdrawableAsset[] memory withdrawableAssets = wc.getWithdrawableAssets(creditManager);

        for (uint256 i = 0; i < withdrawableAssets.length; i++) {
            address token = withdrawableAssets[i].token;
            deal(token, creditAccount, 50e18);

            RequestableWithdrawal memory requestableWithdrawal =
                wc.getWithdrawalRequestResult(creditAccount, token, 50e18);

            vm.prank(user);
            ICreditFacadeV3(creditFacade).multicall(creditAccount, requestableWithdrawal.requestCalls);

            IERC20(withdrawableAssets[i].withdrawalPhantomToken).balanceOf(creditAccount);
            IERC20(withdrawableAssets[i].underlying).balanceOf(creditAccount);

            wc.getCurrentWithdrawals(creditAccount);

            _fulfillWithdrawal(creditAccount, withdrawableAssets[i].withdrawalPhantomToken, requestableWithdrawal.claimableAt);

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
        } else if (cType == "PHANTOM_TOKEN::MIDAS_REDEMPTION") {
            vm.warp(claimableAt + 1);
            address gateway = MidasRedemptionVaultPhantomToken(withdrawalPhantomToken).gateway();
            address midasRedemptionVault = MidasRedemptionVaultGateway(gateway).midasRedemptionVault();
            (,uint256 requestId,,) = MidasRedemptionVaultGateway(gateway).pendingRedemptions(creditAccount);
            address mTokenDataFeed = IMidasRedemptionVaultExt(midasRedemptionVault).mTokenDataFeed();
            uint256 mTokenRate = IMidasDataFeed(mTokenDataFeed).getDataInBase18();

            vm.prank(0x2ACB4BdCbEf02f81BF713b696Ac26390d7f79A12);
            IMidasRedemptionVaultExt(midasRedemptionVault).safeApproveRequest(requestId, mTokenRate);
        }
    }
}
