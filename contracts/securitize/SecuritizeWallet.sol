// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {ISecuritizeKYCFactory} from "./interfaces/ISecuritizeKYCFactory.sol";
import {ISecuritizeWallet} from "./interfaces/ISecuritizeWallet.sol";
import {IKYCUnderlying} from "./interfaces/base/IKYCUnderlying.sol";

/// @title  Securitize Wallet
/// @author Gearbox Foundation
/// @notice A simple wallet contract that owns a credit account and allows investor to interact with it,
///         while also allowing Securitize to enforce compliance
contract SecuritizeWallet is ISecuritizeWallet {
    using SafeERC20 for IERC20;

    address public immutable override factory;
    address public immutable override underlying;
    address public immutable override creditManager;
    address public immutable override creditAccount;

    modifier onlyFactory() {
        if (msg.sender != factory) revert CallerIsNotFactoryException(msg.sender);
        _;
    }

    modifier onlyInvestor() {
        if (msg.sender != _investor()) revert CallerIsNotInvestorException(msg.sender, creditAccount);
        _;
    }

    constructor(address factory_, address creditManager_) {
        factory = factory_;
        underlying = ICreditManagerV3(creditManager_).underlying();
        creditManager = creditManager_;
        creditAccount = _creditFacade().openCreditAccount(address(this), new MultiCall[](0), 0);
    }

    function multicall(MultiCall[] calldata calls) external override onlyFactory {
        address investor = _investor();
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            if (bytes4(calls[i].callData[:4]) == ICreditFacadeV3Multicall.addCollateral.selector) {
                (address token, uint256 amount) = abi.decode(calls[i].callData[4:], (address, uint256));
                _addCollateral(token, investor, amount);
            } else if (bytes4(calls[i].callData[:4]) == ICreditFacadeV3Multicall.addCollateralWithPermit.selector) {
                (address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
                    abi.decode(calls[i].callData[4:], (address, uint256, uint256, uint8, bytes32, bytes32));
                try IERC20Permit(token).permit(investor, address(this), amount, deadline, v, r, s) {} catch {}
                _addCollateral(token, investor, amount);
            } else if (bytes4(calls[i].callData[:4]) == ICreditFacadeV3Multicall.increaseDebt.selector) {
                uint256 amount = abi.decode(calls[i].callData[4:], (uint256));
                IKYCUnderlying(underlying).beforeTokenBorrow(creditAccount, amount);
            } else if (bytes4(calls[i].callData[:4]) == ICreditFacadeV3Multicall.setBotPermissions.selector) {
                revert ForbiddenCallException();
            }
        }
        _creditFacade().multicall(creditAccount, calls);
    }

    function rescueToken(address token, address to) external override onlyInvestor {
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }

    function _addCollateral(address token, address investor, uint256 amount) internal {
        IERC20(token).safeTransferFrom(investor, address(this), amount);
        IERC20(token).forceApprove(creditManager, amount);
    }

    function _creditFacade() internal view returns (ICreditFacadeV3) {
        return ICreditFacadeV3(ICreditManagerV3(creditManager).creditFacade());
    }

    function _investor() internal view returns (address) {
        return ISecuritizeKYCFactory(factory).getInvestor(creditAccount);
    }
}
