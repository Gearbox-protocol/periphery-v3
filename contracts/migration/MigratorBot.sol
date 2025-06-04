// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {
    INACTIVE_CREDIT_ACCOUNT_ADDRESS,
    UNDERLYING_TOKEN_MASK
} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {
    ICreditManagerV3,
    CollateralDebtData,
    CollateralCalcTask
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    ICreditFacadeV3Multicall,
    EXTERNAL_CALLS_PERMISSION,
    UPDATE_QUOTA_PERMISSION,
    DECREASE_DEBT_PERMISSION
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {IBot} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IBot.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {BitMask} from "@gearbox-protocol/core-v3/contracts/libraries/BitMask.sol";
import {CreditLogic} from "@gearbox-protocol/core-v3/contracts/libraries/CreditLogic.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";

struct MigrationParams {
    address accountOwner;
    address newCreditManager;
    address[] collaterals;
    uint256[] amounts;
    uint96[] quotas;
    address underlying;
    uint256 debtAmount;
    PriceUpdate[] priceUpdates;
}

interface IMigratorAdapter {
    function unlock() external;
    function lock() external;
    function migrate(MigrationParams memory params) external;
}

contract MigratorBot is IBot {
    using SafeERC20 for IERC20;
    using BitMask for uint256;
    using CreditLogic for CollateralDebtData;

    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "BOT::MIGRATOR";

    uint192 public constant override requiredPermissions =
        EXTERNAL_CALLS_PERMISSION | UPDATE_QUOTA_PERMISSION | DECREASE_DEBT_PERMISSION;

    address internal activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;

    function migrateCreditAccount(address creditAccount, address newCreditManager, PriceUpdate[] memory priceUpdates)
        external
    {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();

        address accountOwner = ICreditManagerV3(creditManager).getBorrowerOrRevert(creditAccount);

        if (msg.sender != accountOwner) {
            revert("MigratorBot: caller is not the account owner");
        }

        address creditFacade = ICreditManagerV3(creditManager).creditFacade();
        address adapter = ICreditManagerV3(creditManager).contractToAdapter(address(this));

        MigrationParams memory params =
            _getMigrationParams(creditManager, newCreditManager, accountOwner, creditAccount, priceUpdates);

        MultiCall[] memory calls = _getClosingMultiCalls(creditFacade, adapter, params);

        _unlockAdapter(creditAccount, adapter);
        ICreditFacadeV3(creditFacade).botMulticall(creditAccount, calls);
        _lockAdapter(adapter);
    }

    function migrate(MigrationParams memory params) external {
        if (msg.sender != activeCreditAccount) {
            revert("MigratorBot: caller is not the active credit account");
        }

        uint256 len = params.collaterals.length;

        for (uint256 i = 0; i < len; i++) {
            IERC20(params.collaterals[i]).safeTransferFrom(msg.sender, address(this), params.amounts[i]);
            IERC20(params.collaterals[i]).forceApprove(params.newCreditManager, params.amounts[i]);
        }

        address creditFacade = ICreditManagerV3(params.newCreditManager).creditFacade();

        MultiCall[] memory calls = _getOpeningMultiCalls(creditFacade, params);

        ICreditFacadeV3(creditFacade).openCreditAccount(params.accountOwner, calls, 0);

        IERC20(params.underlying).safeTransfer(params.accountOwner, params.debtAmount);
    }

    function _getOpeningMultiCalls(address creditFacade, MigrationParams memory params)
        internal
        view
        returns (MultiCall[] memory calls)
    {
        uint256 len0 = params.collaterals.length;
        uint256 len1 = params.quotas.length;
        calls = new MultiCall[](len0 + len1 + 3);

        calls[0] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdates, (params.priceUpdates))
        });

        for (uint256 i = 0; i < len0; i++) {
            calls[i + 1] = MultiCall({
                target: creditFacade,
                callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (params.collaterals[i], params.amounts[i]))
            });
        }

        for (uint256 i = 0; i < len1; i++) {
            calls[len0 + i + 1] = MultiCall({
                target: creditFacade,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (params.collaterals[i], int96(params.quotas[i]), params.quotas[i])
                )
            });
        }

        calls[len0 + len1 + 1] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (params.debtAmount))
        });

        calls[len0 + len1 + 2] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral, (params.underlying, params.debtAmount, address(this))
            )
        });
    }

    function _getClosingMultiCalls(
        address creditFacade,
        address adapter,
        MigrationParams memory params
    ) internal pure returns (MultiCall[] memory calls) {
        uint256 len = params.quotas.length;

        calls = new MultiCall[](len + 2);

        calls[0] = MultiCall({target: adapter, callData: abi.encodeCall(IMigratorAdapter.migrate, (params))});

        for (uint256 i = 0; i < len; i++) {
            calls[i + 1] = MultiCall({
                target: creditFacade,
                callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (params.collaterals[i], type(int96).min, 0))
            });
        }

        calls[len + 1] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (type(uint256).max))
        });

        return calls;
    }

    function _getMigrationParams(
        address creditManager,
        address newCreditManager,
        address accountOwner,
        address creditAccount,
        PriceUpdate[] memory priceUpdates
    ) internal view returns (MigrationParams memory params) {
        params.newCreditManager = newCreditManager;
        params.priceUpdates = priceUpdates;
        params.accountOwner = accountOwner;
        params.underlying = ICreditManagerV3(creditManager).underlying();
        CollateralDebtData memory cdd =
            ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);
        params.debtAmount = cdd.calcTotalDebt();
        (params.collaterals, params.amounts, params.quotas) = _getAccountCollaterals(creditManager, creditAccount);

        return params;
    }

    function _getAccountCollaterals(address creditManager, address creditAccount)
        internal
        view
        returns (address[] memory, uint256[] memory, uint96[] memory)
    {
        address poolQuotaKeeper = ICreditManagerV3(creditManager).poolQuotaKeeper();
        address underlying = ICreditManagerV3(creditManager).underlying();
        (,,,, uint256 enabledTokensMask,,,) = ICreditManagerV3(creditManager).creditAccountInfo(creditAccount);

        uint256 len = enabledTokensMask.calcEnabledTokens();

        address[] memory collaterals;
        uint256[] memory amounts;
        uint96[] memory quotas;

        uint256 underlyingBalance = IERC20(underlying).balanceOf(creditAccount);
        if (underlyingBalance > 0) {
            collaterals = new address[](len);
            amounts = new uint256[](len);
            quotas = new uint96[](len - 1);

            collaterals[len - 1] = underlying;
            amounts[len - 1] = underlyingBalance;
            enabledTokensMask = enabledTokensMask.disable(UNDERLYING_TOKEN_MASK);
        } else {
            collaterals = new address[](len);
            amounts = new uint256[](len);
            quotas = new uint96[](len);
        }

        uint256 idx;
        while (enabledTokensMask != 0) {
            uint256 tokenMask = enabledTokensMask.lsbMask();

            collaterals[idx] = ICreditManagerV3(creditManager).getTokenByMask(tokenMask);
            amounts[idx] = IERC20(collaterals[idx]).balanceOf(creditAccount);
            if (collaterals[idx] != underlying) {
                (quotas[idx],) = IPoolQuotaKeeperV3(poolQuotaKeeper).getQuota(creditAccount, collaterals[idx]);
            }

            enabledTokensMask = enabledTokensMask.disable(tokenMask);
            idx++;
        }

        return (collaterals, amounts, quotas);
    }

    function _unlockAdapter(address creditAccount, address adapter) internal {
        activeCreditAccount = creditAccount;
        IMigratorAdapter(adapter).unlock();
    }

    function _lockAdapter(address adapter) internal {
        activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;
        IMigratorAdapter(adapter).lock();
    }

    function serialize() external pure override returns (bytes memory) {
        return "";
    }
}
