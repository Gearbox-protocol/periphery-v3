// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RequestStatus} from "midas/interfaces/IManageableVault.sol";

import {MidasV2ForkBase} from "./MidasV2ForkBase.sol";

/// @notice Smoke-tests new plain midas vaults (mfONE + mGLOBAL) on a mainnet fork.
contract MidasV2ForkTest is MidasV2ForkBase {
    function test_mfONE_depositInstant() public {
        uint256 mBefore = IERC20(MFONE).balanceOf(user);
        _approveUsdc(address(mfoneDv), DEPOSIT_USDC_RAW);

        vm.prank(user);
        uint256 minted = mfoneDv.depositInstant(USDC, DEPOSIT_USDC_BASE18, 0, bytes32(0));

        assertGt(minted, 0, "mfONE instant mint");
        assertEq(IERC20(MFONE).balanceOf(user), mBefore + minted, "mfONE balance");
    }

    function test_mfONE_redeemRequest_and_approve() public {
        _approveUsdc(address(mfoneDv), DEPOSIT_USDC_RAW);
        vm.prank(user);
        uint256 minted = mfoneDv.depositInstant(USDC, DEPOSIT_USDC_BASE18, 0, bytes32(0));
        // Keep above RV minAmount (1e18).
        uint256 redeemAmount = minted / 2;
        if (redeemAmount < 1e18) redeemAmount = minted;

        _approveMToken(MFONE, address(mfoneRv), redeemAmount);

        vm.prank(user);
        uint256 requestId = mfoneRv.redeemRequest(USDC, redeemAmount);

        // mToken moved to requestRedeemer pending approval.
        assertEq(IERC20(MFONE).balanceOf(requestRedeemer), redeemAmount, "pending mToken");

        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        uint256 mTokenRate = mfoneRv.mTokenDataFeed().getDataInBase18();

        vm.prank(DEFAULT_ADMIN);
        mfoneRv.approveRequest(requestId, mTokenRate, false);

        (,, RequestStatus status,,,,,,,) = mfoneRv.redeemRequests(requestId);
        assertEq(uint8(status), uint8(RequestStatus.Processed), "mfONE redeem approved");
        assertGt(IERC20(USDC).balanceOf(user), usdcBefore, "USDC received");
        assertEq(IERC20(MFONE).balanceOf(requestRedeemer), 0, "mToken burned");
    }

    function test_mGLOBAL_hybridDeposit_and_approveHoldback() public {
        _approveUsdc(address(mglobalDv), DEPOSIT_USDC_RAW);

        vm.prank(user);
        (uint256 requestId, uint256 instantMinted) = mglobalDv.depositRequest(
            USDC,
            DEPOSIT_USDC_BASE18,
            bytes32(0),
            user,
            MAX_INSTANT_SHARE_MGLOBAL,
            0,
            user
        );

        assertGt(instantMinted, 0, "mGLOBAL instant portion");
        assertGt(IERC20(MGLOBAL).balanceOf(user), 0, "instant mGLOBAL");

        uint256 mTokenRate = mglobalDv.mTokenDataFeed().getDataInBase18();
        uint256 mBefore = IERC20(MGLOBAL).balanceOf(user);

        vm.prank(DEFAULT_ADMIN);
        mglobalDv.approveRequest(requestId, mTokenRate, false);

        (,, RequestStatus status,,,,,,) = mglobalDv.mintRequests(requestId);
        assertEq(uint8(status), uint8(RequestStatus.Processed), "mGLOBAL deposit approved");
        assertGt(IERC20(MGLOBAL).balanceOf(user), mBefore, "holdback minted");
    }

    function test_mGLOBAL_hybridRedeem_and_approveHoldback() public {
        // Seed mGLOBAL via hybrid deposit + approve.
        _approveUsdc(address(mglobalDv), DEPOSIT_USDC_RAW);
        vm.prank(user);
        (uint256 depId,) = mglobalDv.depositRequest(
            USDC, DEPOSIT_USDC_BASE18, bytes32(0), user, MAX_INSTANT_SHARE_MGLOBAL, 0, user
        );
        uint256 depRate = mglobalDv.mTokenDataFeed().getDataInBase18();
        vm.prank(DEFAULT_ADMIN);
        mglobalDv.approveRequest(depId, depRate, false);

        uint256 balance = IERC20(MGLOBAL).balanceOf(user);
        require(balance >= 1e18, "insufficient mGLOBAL");
        uint256 redeemAmount = balance / 2;
        if (redeemAmount < 1e18) redeemAmount = balance;

        _approveMToken(MGLOBAL, address(mglobalRv), redeemAmount);

        uint256 usdcBefore = IERC20(USDC).balanceOf(user);

        vm.prank(user);
        (uint256 requestId, uint256 instantOut) = mglobalRv.redeemRequest(
            USDC, redeemAmount, user, MAX_INSTANT_SHARE_MGLOBAL, 0, user
        );
        assertGt(instantOut, 0, "mGLOBAL instant redeem");
        assertGt(IERC20(USDC).balanceOf(user), usdcBefore, "instant USDC");

        uint256 pendingM = IERC20(MGLOBAL).balanceOf(requestRedeemer);
        assertGt(pendingM, 0, "holdback mToken pending");

        uint256 usdcMid = IERC20(USDC).balanceOf(user);
        uint256 redeemRate = mglobalRv.mTokenDataFeed().getDataInBase18();
        vm.prank(DEFAULT_ADMIN);
        mglobalRv.approveRequest(requestId, redeemRate, false);

        (,, RequestStatus status,,,,,,,) = mglobalRv.redeemRequests(requestId);
        assertEq(uint8(status), uint8(RequestStatus.Processed), "mGLOBAL redeem approved");
        assertGt(IERC20(USDC).balanceOf(user), usdcMid, "holdback USDC");
        assertEq(IERC20(MGLOBAL).balanceOf(requestRedeemer), 0, "holdback burned");
    }

    function test_mfONE_redeemInstant_reverts_when_maxInstantShare_zero() public {
        _approveUsdc(address(mfoneDv), DEPOSIT_USDC_RAW);
        vm.prank(user);
        uint256 minted = mfoneDv.depositInstant(USDC, DEPOSIT_USDC_BASE18, 0, bytes32(0));

        _approveMToken(MFONE, address(mfoneRv), minted);
        vm.prank(user);
        vm.expectRevert();
        mfoneRv.redeemInstant(USDC, minted, 0);
    }
}
