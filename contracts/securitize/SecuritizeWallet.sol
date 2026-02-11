// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {ISecuritizeFactory} from "./interfaces/ISecuritizeFactory.sol";
import {ISecuritizeWallet} from "./interfaces/ISecuritizeWallet.sol";

/// @title Securitize Wallet
/// @author Gearbox Foundation
/// @notice A simple wallet contract that owns a credit account and allows investor to interact with it,
///         while also allowing Securitize to enforce compliance
contract SecuritizeWallet is ISecuritizeWallet {
    using SafeERC20 for IERC20;

    address public immutable override factory;
    address public immutable override creditManager;
    address public immutable override creditAccount;

    modifier onlyFactory() {
        if (msg.sender != factory) revert CallerIsNotFactoryException(msg.sender);
        _;
    }

    constructor(address factory_, address creditManager_) {
        factory = factory_;
        creditManager = creditManager_;
        creditAccount = _creditFacade().openCreditAccount(address(this), new MultiCall[](0), 0);
    }

    function multicall(MultiCall[] calldata calls) external override onlyFactory {
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            if (bytes4(calls[i].callData[:4]) == ICreditFacadeV3Multicall.setBotPermissions.selector) {
                revert ForbiddenCallException();
            }
        }
        _creditFacade().multicall(creditAccount, calls);
    }

    function receiveToken(address token, address from, uint256 amount) external override onlyFactory {
        IERC20(token).safeTransferFrom(from, address(this), amount);
    }

    function approveToken(address token, address to, uint256 amount) external override onlyFactory {
        IERC20(token).forceApprove(to, amount);
    }

    function sendToken(address token, address to, uint256 amount) external override onlyFactory {
        if (amount == type(uint256).max) amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
    }

    function _creditFacade() internal view returns (ICreditFacadeV3) {
        return ICreditFacadeV3(ICreditManagerV3(creditManager).creditFacade());
    }
}
