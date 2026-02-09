// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {ISecuritizeFactory} from "./interfaces/ISecuritizeFactory.sol";

/// @title Securitize Wallet
/// @author Gearbox Foundation
/// @notice A simple wallet contract that owns a credit account and allows investor to interact with it,
///         while also allowing Securitize to enforce compliance
contract SecuritizeWallet {
    using SafeERC20 for IERC20;

    ISecuritizeFactory public immutable FACTORY;
    ICreditManagerV3 public immutable CREDIT_MANAGER;
    address public immutable CREDIT_ACCOUNT;

    error CallerIsNotInvestorException(address caller);
    error CallerIsNotSelfException(address caller);
    error FrozenCreditAccountException(address creditAccount);
    error ExecutionFailedException();
    error ForbiddenCallException();

    modifier onlyInvestor() {
        if (msg.sender != FACTORY.getInvestor(CREDIT_ACCOUNT)) revert CallerIsNotInvestorException(msg.sender);
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert CallerIsNotSelfException(msg.sender);
        _;
    }

    modifier whenNotFrozen() {
        if (FACTORY.isFrozen(CREDIT_ACCOUNT)) revert FrozenCreditAccountException(CREDIT_ACCOUNT);
        _;
    }

    constructor(ISecuritizeFactory factory, ICreditManagerV3 creditManager) {
        FACTORY = factory;
        CREDIT_MANAGER = creditManager;
        CREDIT_ACCOUNT = _creditFacade().openCreditAccount(address(this), new MultiCall[](0), 0);
    }

    function execute(bytes[] calldata calls) external onlyInvestor whenNotFrozen {
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            // TODO: implement some cheaper dispatching instead of self-calls
            (bool success,) = address(this).call(calls[i]);
            if (!success) revert ExecutionFailedException();
        }
    }

    function multicall(MultiCall[] calldata calls) external onlySelf {
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            if (bytes4(calls[i].callData[:4]) == ICreditFacadeV3Multicall.setBotPermissions.selector) {
                revert ForbiddenCallException();
            }
        }
        _creditFacade().multicall(CREDIT_ACCOUNT, calls);
    }

    function approveToken(address token, address to, uint256 amount) external onlySelf {
        IERC20(token).forceApprove(to, amount);
    }

    function sendToken(address token, address to, uint256 amount) external onlySelf {
        IERC20(token).safeTransfer(to, amount);
    }

    function receiveToken(address token, address from, uint256 amount) external onlySelf {
        IERC20(token).safeTransferFrom(from, address(this), amount);
    }

    function _creditFacade() internal view returns (ICreditFacadeV3) {
        return ICreditFacadeV3(CREDIT_MANAGER.creditFacade());
    }
}
