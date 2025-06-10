// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {
    INACTIVE_CREDIT_ACCOUNT_ADDRESS,
    UNDERLYING_TOKEN_MASK,
    WAD,
    PERCENTAGE_FACTOR
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
    DECREASE_DEBT_PERMISSION,
    INCREASE_DEBT_PERMISSION,
    WITHDRAW_COLLATERAL_PERMISSION
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {IBot} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IBot.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IInterestRateModel} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IInterestRateModel.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {IPriceFeedStore} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {BitMask} from "@gearbox-protocol/core-v3/contracts/libraries/BitMask.sol";
import {CreditLogic} from "@gearbox-protocol/core-v3/contracts/libraries/CreditLogic.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";

struct MigratedCollateral {
    address collateral;
    uint256 amount;
    uint96 targetQuotaIncrease;
    bool underlyingInSource;
    bool underlyingInTarget;
}

struct FailureStates {
    bool targetHFTooLow;
    bool sourceUnderlyingIsNotCollateral;
    bool migratedCollateralDoesNotExistInTarget;
    bool insufficientTargetQuotaLimits;
    bool insufficientTargetBorrowLiquidity;
    bool insufficientTargetDebtLimit;
    bool newTargetDebtOutOfLimits;
    bool noPathToSourceUnderlying;
    bool cannotSwapEnoughToCoverDebt;
}

struct MigrationParams {
    address sourceCreditAccount;
    address targetCreditAccount;
    MigratedCollateral[] migratedCollaterals;
    uint256 targetBorrowAmount;
    MultiCall[] underlyingSwapCalls;
}

struct PreviewMigrationResult {
    bool success;
    uint256 expectedTargetHF;
    FailureStates failureStates;
    MigrationParams migrationParams;
}

interface IMigratorAdapter {
    function unlock() external;
    function lock() external;
    function migrate(MigrationParams memory params) external;
}

struct RouterResult {
    uint256 amount;
    uint256 minAmount;
    MultiCall[] calls;
}

interface IGearboxRouter {
    function routeOneToOne(
        address creditAccount,
        address tokenIn,
        uint256 amount,
        address target,
        uint256 slippage,
        uint256 numSplits
    ) external returns (RouterResult memory);
}

contract MigratorBot is IBot {
    using SafeERC20 for IERC20;
    using BitMask for uint256;
    using CreditLogic for CollateralDebtData;

    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "BOT::MIGRATOR";

    address public immutable router;

    uint192 public constant override requiredPermissions = EXTERNAL_CALLS_PERMISSION | UPDATE_QUOTA_PERMISSION
        | DECREASE_DEBT_PERMISSION | INCREASE_DEBT_PERMISSION | WITHDRAW_COLLATERAL_PERMISSION;

    address internal activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;

    constructor(address _router) {
        router = _router;
    }

    /// PREVIEW LOGIC

    function previewMigration(
        address sourceCreditAccount,
        address targetCreditAccount,
        PriceUpdate[] memory priceUpdates
    ) external returns (PreviewMigrationResult memory result) {
        _applyPriceUpdates(targetCreditAccount, priceUpdates);

        result.success = true;
        result.migrationParams.sourceCreditAccount = sourceCreditAccount;
        result.migrationParams.targetCreditAccount = targetCreditAccount;

        _populateMigrationParams(result);
    }

    function _populateMigrationParams(PreviewMigrationResult memory result) internal {
        address sourceCreditManager = ICreditAccountV3(result.migrationParams.sourceCreditAccount).creditManager();

        _checkSourceUnderlyingIsCollateral(result, sourceCreditManager);

        if (!result.success) {
            return;
        }

        uint256 underlyingRate = _getUnderlyingRate(sourceCreditManager, result.migrationParams.targetCreditAccount);

        _populateMigratedCollaterals(result, sourceCreditManager, underlyingRate);
        _populateDebtAndSwapCalls(result, sourceCreditManager, underlyingRate);

        _checkFailureStates(result);
    }

    function _checkSourceUnderlyingIsCollateral(PreviewMigrationResult memory result, address sourceCreditManager)
        internal
        view
    {
        address targetCreditManager = ICreditAccountV3(result.migrationParams.targetCreditAccount).creditManager();
        address sourceUnderlying = ICreditManagerV3(sourceCreditManager).underlying();

        try ICreditManagerV3(targetCreditManager).getTokenMaskOrRevert(sourceUnderlying) returns (uint256) {}
        catch {
            result.success = false;
            result.failureStates.sourceUnderlyingIsNotCollateral = true;
        }
    }

    function _checkTargetCollaterals(PreviewMigrationResult memory result) internal view {
        address sourceCreditManager = ICreditAccountV3(result.migrationParams.sourceCreditAccount).creditManager();
        address targetCreditManager = ICreditAccountV3(result.migrationParams.targetCreditAccount).creditManager();

        address sourcePool = ICreditManagerV3(sourceCreditManager).pool();
        address targetPool = ICreditManagerV3(targetCreditManager).pool();

        if (sourcePool != targetPool) {
            for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
                if (!result.migrationParams.migratedCollaterals[i].underlyingInTarget) {
                    address poolQuotaKeeper = IPoolV3(targetPool).poolQuotaKeeper();

                    try IPoolQuotaKeeperV3(poolQuotaKeeper).getTokenQuotaParams(
                        result.migrationParams.migratedCollaterals[i].collateral
                    ) returns (uint16, uint192, uint16, uint96, uint96, bool) {} catch {
                        result.success = false;
                        result.failureStates.migratedCollateralDoesNotExistInTarget = true;
                    }
                }
            }
        }

        for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
            try ICreditManagerV3(targetCreditManager).getTokenMaskOrRevert(
                result.migrationParams.migratedCollaterals[i].collateral
            ) returns (uint256) {} catch {
                result.success = false;
                result.failureStates.migratedCollateralDoesNotExistInTarget = true;
            }
        }
    }

    function _checkTargetQuotaLimits(PreviewMigrationResult memory result) internal view {
        address sourcePool =
            ICreditManagerV3(ICreditAccountV3(result.migrationParams.sourceCreditAccount).creditManager()).pool();
        address targetPool =
            ICreditManagerV3(ICreditAccountV3(result.migrationParams.targetCreditAccount).creditManager()).pool();

        for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
            address poolQuotaKeeper = IPoolV3(targetPool).poolQuotaKeeper();

            uint96 totalQuoted;
            uint96 limit;

            try IPoolQuotaKeeperV3(poolQuotaKeeper).getTokenQuotaParams(
                result.migrationParams.migratedCollaterals[i].collateral
            ) returns (uint16, uint192, uint16, uint96 _totalQuoted, uint96 _limit, bool) {
                totalQuoted = _totalQuoted;
                limit = _limit;
            } catch {
                result.success = false;
                result.failureStates.insufficientTargetQuotaLimits = true;
            }

            if (sourcePool != targetPool) {
                if (result.migrationParams.migratedCollaterals[i].targetQuotaIncrease + totalQuoted > limit) {
                    result.success = false;
                    result.failureStates.insufficientTargetQuotaLimits = true;
                }
            } else {
                if (totalQuoted > limit) {
                    result.success = false;
                    result.failureStates.insufficientTargetQuotaLimits = true;
                }
            }

            if (result.migrationParams.migratedCollaterals[i].targetQuotaIncrease == 0) {
                result.success = false;
                result.failureStates.insufficientTargetQuotaLimits = true;
            }
        }
    }

    function _checkNewDebt(PreviewMigrationResult memory result) internal view {
        address targetCreditManager = ICreditAccountV3(result.migrationParams.targetCreditAccount).creditManager();
        address targetPool = ICreditManagerV3(targetCreditManager).pool();
        address sourcePool =
            ICreditManagerV3(ICreditAccountV3(result.migrationParams.sourceCreditAccount).creditManager()).pool();

        uint256 creditManagerDebtLimit = IPoolV3(targetPool).creditManagerDebtLimit(targetCreditManager);
        uint256 creditManagerBorrowed = IPoolV3(targetPool).creditManagerBorrowed(targetCreditManager);

        if (result.migrationParams.targetBorrowAmount + creditManagerBorrowed > creditManagerDebtLimit) {
            result.success = false;
            result.failureStates.insufficientTargetDebtLimit = true;
        }

        if (
            result.migrationParams.targetBorrowAmount
                > _computePoolBorrowableLiquidity(
                    targetPool, sourcePool != targetPool ? 0 : result.migrationParams.targetBorrowAmount
                )
        ) {
            result.success = false;
            result.failureStates.insufficientTargetBorrowLiquidity = true;
        }
    }

    function _computePoolBorrowableLiquidity(address pool, uint256 liquidityOffset) internal view returns (uint256) {
        uint256 availableLiquidity = IPoolV3(pool).availableLiquidity();
        uint256 expectedLiquidity = IPoolV3(pool).expectedLiquidity();

        address interestRateModel = IPoolV3(pool).interestRateModel();

        return IInterestRateModel(interestRateModel).availableToBorrow(
            expectedLiquidity, availableLiquidity + liquidityOffset
        );
    }

    function _checkTargetHF(PreviewMigrationResult memory result) internal view {
        address targetCreditManager = ICreditAccountV3(result.migrationParams.targetCreditAccount).creditManager();
        address priceOracle = ICreditManagerV3(targetCreditManager).priceOracle();
        address underlying = ICreditManagerV3(targetCreditManager).underlying();

        CollateralDebtData memory cdd = ICreditManagerV3(targetCreditManager).calcDebtAndCollateral(
            result.migrationParams.targetCreditAccount,
            result.migrationParams.underlyingSwapCalls.length > 0
                ? CollateralCalcTask.DEBT_COLLATERAL_SAFE_PRICES
                : CollateralCalcTask.DEBT_COLLATERAL
        );

        for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
            address collateral = result.migrationParams.migratedCollaterals[i].collateral;

            uint16 lt = ICreditManagerV3(targetCreditManager).liquidationThresholds(collateral);

            if (result.migrationParams.migratedCollaterals[i].underlyingInTarget) {
                cdd.twvUSD += result.migrationParams.migratedCollaterals[i].amount * lt / PERCENTAGE_FACTOR;
            } else {
                uint256 quotaUSD = IPriceOracleV3(priceOracle).convertToUSD(
                    result.migrationParams.migratedCollaterals[i].targetQuotaIncrease, underlying
                );
                uint256 wvUSD = IPriceOracleV3(priceOracle).convertToUSD(
                    result.migrationParams.migratedCollaterals[i].amount, collateral
                ) * lt / PERCENTAGE_FACTOR;

                cdd.twvUSD += wvUSD > quotaUSD ? quotaUSD : wvUSD;
            }
        }

        cdd.totalDebtUSD +=
            IPriceOracleV3(priceOracle).convertToUSD(result.migrationParams.targetBorrowAmount, underlying);

        result.expectedTargetHF = cdd.twvUSD * PERCENTAGE_FACTOR / cdd.totalDebtUSD;

        if (result.expectedTargetHF < 10000) {
            result.success = false;
            result.failureStates.targetHFTooLow = true;
        }
    }

    function _checkFailureStates(PreviewMigrationResult memory result) internal view {
        _checkTargetCollaterals(result);

        if (!result.success && result.failureStates.migratedCollateralDoesNotExistInTarget) {
            return;
        }

        _checkTargetQuotaLimits(result);
        _checkNewDebt(result);
        _checkTargetHF(result);
    }

    function _populateMigratedCollaterals(
        PreviewMigrationResult memory result,
        address sourceCreditManager,
        uint256 underlyingRate
    ) internal view {
        (,,,, uint256 enabledTokensMask,,,) =
            ICreditManagerV3(sourceCreditManager).creditAccountInfo(result.migrationParams.sourceCreditAccount);

        MigratedCollateral[] memory migratedCollaterals =
            new MigratedCollateral[](enabledTokensMask.calcEnabledTokens());

        for (uint256 i = 0; i < migratedCollaterals.length; i++) {
            uint256 tokenMask = enabledTokensMask.lsbMask();
            migratedCollaterals[i].collateral = ICreditManagerV3(sourceCreditManager).getTokenByMask(tokenMask);
            migratedCollaterals[i].amount =
                IERC20(migratedCollaterals[i].collateral).balanceOf(result.migrationParams.sourceCreditAccount);

            (migratedCollaterals[i].underlyingInSource, migratedCollaterals[i].underlyingInTarget) =
            _isCollateralUnderlying(
                sourceCreditManager, result.migrationParams.targetCreditAccount, migratedCollaterals[i].collateral
            );

            migratedCollaterals[i].targetQuotaIncrease = _getTargetQuotaIncrease(
                sourceCreditManager,
                result.migrationParams.sourceCreditAccount,
                underlyingRate,
                migratedCollaterals[i]
            );

            enabledTokensMask = enabledTokensMask.disable(tokenMask);
        }

        result.migrationParams.migratedCollaterals = migratedCollaterals;
    }

    function _populateDebtAndSwapCalls(
        PreviewMigrationResult memory result,
        address sourceCreditManager,
        uint256 underlyingRate
    ) internal {
        address sourceCreditAccount = result.migrationParams.sourceCreditAccount;
        address targetCreditAccount = result.migrationParams.targetCreditAccount;
        address targetCreditManager = ICreditAccountV3(targetCreditAccount).creditManager();

        CollateralDebtData memory cdd = ICreditManagerV3(sourceCreditManager).calcDebtAndCollateral(
            sourceCreditAccount, CollateralCalcTask.DEBT_ONLY
        );
        uint256 debtAmount = cdd.calcTotalDebt();

        if (ICreditManagerV3(sourceCreditManager).underlying() == ICreditManagerV3(targetCreditManager).underlying()) {
            result.migrationParams.targetBorrowAmount = debtAmount;
            return;
        }

        result.migrationParams.targetBorrowAmount = debtAmount * underlyingRate * 10100 / (WAD * 10000);

        try IGearboxRouter(router).routeOneToOne(
            targetCreditAccount,
            ICreditManagerV3(targetCreditManager).underlying(),
            result.migrationParams.targetBorrowAmount,
            ICreditManagerV3(sourceCreditManager).underlying(),
            50,
            2
        ) returns (RouterResult memory routerResult) {
            result.migrationParams.underlyingSwapCalls = routerResult.calls;
            if (routerResult.minAmount < debtAmount) {
                result.success = false;
                result.failureStates.cannotSwapEnoughToCoverDebt = true;
            }
        } catch {
            result.success = false;
            result.failureStates.noPathToSourceUnderlying = true;
        }
    }

    function _getUnderlyingRate(address sourceCreditManager, address targetCreditAccount)
        internal
        view
        returns (uint256)
    {
        address targetCreditManager = ICreditAccountV3(targetCreditAccount).creditManager();
        address targetPriceOracle = ICreditManagerV3(targetCreditManager).priceOracle();

        address sourceUnderlying = ICreditManagerV3(sourceCreditManager).underlying();
        address targetUnderlying = ICreditManagerV3(targetCreditManager).underlying();

        uint256 rate = IPriceOracleV3(targetPriceOracle).convert(WAD, sourceUnderlying, targetUnderlying);

        return rate;
    }

    function _isCollateralUnderlying(address sourceCreditManager, address targetCreditAccount, address collateral)
        internal
        view
        returns (bool isUnderlyingInSource, bool isUnderlyingInTarget)
    {
        address targetCreditManager = ICreditAccountV3(targetCreditAccount).creditManager();

        isUnderlyingInSource = ICreditManagerV3(sourceCreditManager).underlying() == collateral;
        isUnderlyingInTarget = ICreditManagerV3(targetCreditManager).underlying() == collateral;
    }

    function _getTargetQuotaIncrease(
        address sourceCreditManager,
        address sourceCreditAccount,
        uint256 underlyingRate,
        MigratedCollateral memory collateral
    ) internal view returns (uint96) {
        if (collateral.underlyingInTarget) {
            return 0;
        } else if (!collateral.underlyingInSource) {
            (uint96 sourceQuota,) = IPoolQuotaKeeperV3(ICreditManagerV3(sourceCreditManager).poolQuotaKeeper()).getQuota(
                sourceCreditAccount, collateral.collateral
            );
            return uint96(sourceQuota * underlyingRate / WAD);
        } else {
            return uint96(collateral.amount * 10050 * underlyingRate / (WAD * 10000));
        }
    }

    /// EXECUTION LOGIC

    function migrateCreditAccount(MigrationParams memory params, PriceUpdate[] memory priceUpdates) external {
        _applyPriceUpdates(params.targetCreditAccount, priceUpdates);
        _checkAccountOwner(params);

        address sourceCreditManager = ICreditAccountV3(params.sourceCreditAccount).creditManager();
        address creditFacade = ICreditManagerV3(sourceCreditManager).creditFacade();
        address adapter = ICreditManagerV3(sourceCreditManager).contractToAdapter(address(this));

        MultiCall[] memory calls = _getClosingMultiCalls(creditFacade, adapter, params);

        _unlockAdapter(params.sourceCreditAccount, adapter);
        ICreditFacadeV3(creditFacade).botMulticall(params.sourceCreditAccount, calls);
        _lockAdapter(adapter);
    }

    function migrate(MigrationParams memory params) external {
        if (msg.sender != activeCreditAccount) {
            revert("MigratorBot: caller is not the active credit account");
        }

        uint256 len = params.migratedCollaterals.length;

        for (uint256 i = 0; i < len; i++) {
            IERC20(params.migratedCollaterals[i].collateral).safeTransferFrom(
                msg.sender, params.targetCreditAccount, params.migratedCollaterals[i].amount
            );
        }

        address targetCreditManager = ICreditAccountV3(params.targetCreditAccount).creditManager();
        address targetCreditFacade = ICreditManagerV3(targetCreditManager).creditFacade();

        MultiCall[] memory calls = _getOpeningMultiCalls(targetCreditFacade, params);

        ICreditFacadeV3(targetCreditFacade).botMulticall(params.targetCreditAccount, calls);
    }

    function _getOpeningMultiCalls(address creditFacade, MigrationParams memory params)
        internal
        view
        returns (MultiCall[] memory calls)
    {
        uint256 quotasCalls;
        uint256 underlyingSwapCalls = params.underlyingSwapCalls.length;

        for (uint256 i = 0; i < params.migratedCollaterals.length; i++) {
            if (params.migratedCollaterals[i].targetQuotaIncrease > 0) {
                quotasCalls++;
            }
        }

        calls = new MultiCall[](quotasCalls + underlyingSwapCalls + 2);

        uint256 k = 0;

        for (uint256 i = 0; i < params.migratedCollaterals.length; i++) {
            if (params.migratedCollaterals[i].targetQuotaIncrease > 0) {
                calls[k + 1] = MultiCall({
                    target: creditFacade,
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.updateQuota,
                        (
                            params.migratedCollaterals[i].collateral,
                            int96(params.migratedCollaterals[i].targetQuotaIncrease),
                            params.migratedCollaterals[i].targetQuotaIncrease
                        )
                    )
                });
                ++k;
            }
        }

        calls[quotasCalls] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (params.targetBorrowAmount))
        });

        for (uint256 i = 0; i < underlyingSwapCalls; i++) {
            calls[quotasCalls + i + 1] = params.underlyingSwapCalls[i];
        }

        calls[quotasCalls + underlyingSwapCalls + 1] = _getUnderlyingWithdrawCall(creditFacade, params);
    }

    function _getUnderlyingWithdrawCall(address creditFacade, MigrationParams memory params)
        internal
        view
        returns (MultiCall memory call)
    {
        address underlying = ICreditManagerV3(ICreditAccountV3(params.sourceCreditAccount).creditManager()).underlying();
        uint256 totalDebt = _getAccountTotalDebt(params.sourceCreditAccount);

        return MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral, (underlying, totalDebt, params.sourceCreditAccount)
            )
        });
    }

    function _getClosingMultiCalls(address creditFacade, address adapter, MigrationParams memory params)
        internal
        pure
        returns (MultiCall[] memory calls)
    {
        uint256 nCollaterals = params.migratedCollaterals.length;
        uint256 quotasCalls;

        for (uint256 i = 0; i < nCollaterals; i++) {
            if (!params.migratedCollaterals[i].underlyingInSource) {
                quotasCalls++;
            }
        }

        calls = new MultiCall[](quotasCalls + 2);
        calls[0] = MultiCall({target: adapter, callData: abi.encodeCall(IMigratorAdapter.migrate, (params))});

        uint256 k = 0;

        for (uint256 i = 0; i < nCollaterals; i++) {
            if (!params.migratedCollaterals[i].underlyingInSource) {
                calls[k + 1] = MultiCall({
                    target: creditFacade,
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.updateQuota, (params.migratedCollaterals[i].collateral, type(int96).min, 0)
                    )
                });
                ++k;
            }
        }

        calls[quotasCalls + 1] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (type(uint256).max))
        });

        return calls;
    }

    function _getAccountTotalDebt(address creditAccount) internal view returns (uint256) {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();

        CollateralDebtData memory cdd =
            ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        return cdd.calcTotalDebt();
    }

    function _checkAccountOwner(MigrationParams memory params) internal view {
        address sourceCreditManager = ICreditAccountV3(params.sourceCreditAccount).creditManager();
        address sourceAccountOwner =
            ICreditManagerV3(sourceCreditManager).getBorrowerOrRevert(params.sourceCreditAccount);

        address targetCreditManager = ICreditAccountV3(params.targetCreditAccount).creditManager();
        address targetAccountOwner =
            ICreditManagerV3(targetCreditManager).getBorrowerOrRevert(params.targetCreditAccount);

        if (msg.sender != sourceAccountOwner || msg.sender != targetAccountOwner) {
            revert("MigratorBot: caller is not the account owner");
        }
    }

    function _applyPriceUpdates(address creditAccount, PriceUpdate[] memory priceUpdates) internal {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        address creditFacade = ICreditManagerV3(creditManager).creditFacade();
        address priceFeedStore = ICreditFacadeV3(creditFacade).priceFeedStore();

        IPriceFeedStore(priceFeedStore).updatePrices(priceUpdates);
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
