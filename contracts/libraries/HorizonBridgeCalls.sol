// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {IHorizonGearboxBridge} from "../interfaces/IHorizonGearboxBridge.sol";

/// @title Selector / target validation for HorizonGearboxBridge user multicalls
library HorizonBridgeCalls {
    /// @dev Open / immediate conversion: slippage helpers + on-demand prices + full-check params
    function isSlippageOrPriceSelector(bytes4 selector) internal pure returns (bool) {
        return selector == ICreditFacadeV3Multicall.storeExpectedBalances.selector
            || selector == ICreditFacadeV3Multicall.compareBalances.selector
            || selector == ICreditFacadeV3Multicall.onDemandPriceUpdates.selector
            || selector == ICreditFacadeV3Multicall.setFullCheckParams.selector;
    }

    /// @dev Close conversion extras: quota / debt management (and withdraw with recipient check)
    function isCloseDebtSelector(bytes4 selector) internal pure returns (bool) {
        return selector == ICreditFacadeV3Multicall.updateQuota.selector
            || selector == ICreditFacadeV3Multicall.increaseDebt.selector
            || selector == ICreditFacadeV3Multicall.decreaseDebt.selector
            || selector == ICreditFacadeV3Multicall.withdrawCollateral.selector;
    }

    /// @notice Validates openPosition user calls: facade slippage/price selectors or known adapters
    function validateOpenCalls(address creditManager, MultiCall[] calldata calls) internal view {
        address facade = ICreditManagerV3(creditManager).creditFacade();
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            address target = calls[i].target;
            if (target == facade) {
                bytes4 selector = bytes4(calls[i].callData[:4]);
                if (!isSlippageOrPriceSelector(selector)) {
                    revert IHorizonGearboxBridge.ForbiddenFacadeSelectorException(selector);
                }
            } else {
                _ensureAdapter(creditManager, target);
            }
        }
    }

    /// @notice Validates closeImmediate / closeDelayed conversion calls
    /// @dev `withdrawCollateral` is allowed only when recipient is `allowedWithdrawTo`
    function validateCloseCalls(address creditManager, MultiCall[] calldata calls, address allowedWithdrawTo)
        internal
        view
    {
        address facade = ICreditManagerV3(creditManager).creditFacade();
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            address target = calls[i].target;
            if (target == facade) {
                bytes4 selector = bytes4(calls[i].callData[:4]);
                if (isSlippageOrPriceSelector(selector) || isCloseDebtSelector(selector)) {
                    if (selector == ICreditFacadeV3Multicall.withdrawCollateral.selector) {
                        (,, address to) = abi.decode(calls[i].callData[4:], (address, uint256, address));
                        if (to != allowedWithdrawTo) {
                            revert IHorizonGearboxBridge.ForbiddenWithdrawRecipientException(to);
                        }
                    }
                } else {
                    revert IHorizonGearboxBridge.ForbiddenFacadeSelectorException(selector);
                }
            } else {
                _ensureAdapter(creditManager, target);
            }
        }
    }

    function _ensureAdapter(address creditManager, address target) private view {
        if (ICreditManagerV3(creditManager).adapterToContract(target) == address(0)) {
            revert IHorizonGearboxBridge.UnknownAdapterException(target);
        }
    }
}
