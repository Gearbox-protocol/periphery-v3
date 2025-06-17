// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAccountMigratorBot, IAccountMigratorAdapter} from "../interfaces/IAccountMigratorBot.sol";
import {
    MigrationParams,
    PreviewMigrationResult,
    MigratedCollateral,
    PhantomTokenParams,
    PhantomTokenOverride
} from "../types/AccountMigrationTypes.sol";
import {IGearboxRouter, RouterResult, TokenData} from "../interfaces/external/IGearboxRouter.sol";
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
import {OptionalCall} from "@gearbox-protocol/core-v3/contracts/libraries/OptionalCall.sol";
import {
    IPhantomToken, IPhantomTokenAdapter
} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPhantomToken.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IInterestRateModel} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IInterestRateModel.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {IPriceFeedStore} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {ACLTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLTrait.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {IMarketConfiguratorFactory} from
    "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfiguratorFactory.sol";
import {IContractsRegister} from "@gearbox-protocol/permissionless/contracts/interfaces/IContractsRegister.sol";
import {BitMask} from "@gearbox-protocol/core-v3/contracts/libraries/BitMask.sol";
import {CreditLogic} from "@gearbox-protocol/core-v3/contracts/libraries/CreditLogic.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";

contract MigratorBot is Ownable, IAccountMigratorBot {
    using SafeERC20 for IERC20;
    using BitMask for uint256;
    using CreditLogic for CollateralDebtData;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "BOT::ACCOUNT_MIGRATOR";

    mapping(address => PhantomTokenOverride) public phantomTokenOverrides;

    EnumerableSet.AddressSet internal _overridenPhantomTokens;

    address public immutable router;

    address public immutable mcFactory;

    uint192 public constant override requiredPermissions =
        EXTERNAL_CALLS_PERMISSION | UPDATE_QUOTA_PERMISSION | DECREASE_DEBT_PERMISSION;

    address internal activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;

    constructor(address _mcFactory, address _ioProxy, address _router) {
        _transferOwnership(_ioProxy);
        router = _router;
        mcFactory = _mcFactory;
    }

    /// PREVIEW LOGIC

    /// @notice Previews migration and prepares the required migration parameters.
    ///         Also returns whether the migration will fail and failure reasons, if so.
    /// @param sourceCreditAccount The credit account to migrate from.
    /// @param targetCreditManager The credit manager to migrate to.
    /// @param priceUpdates The price updates to apply.
    /// @return result The preview migration result.
    function previewMigration(
        address sourceCreditAccount,
        address targetCreditManager,
        PriceUpdate[] memory priceUpdates
    ) external returns (PreviewMigrationResult memory result) {
        _applyPriceUpdates(targetCreditManager, priceUpdates);

        result.success = true;
        result.migrationParams.sourceCreditAccount = sourceCreditAccount;
        result.migrationParams.targetCreditManager = targetCreditManager;

        _populateMigrationParams(result);
    }

    /// @dev Populates the migration result struct, including migration parameters and success/failure states.
    function _populateMigrationParams(PreviewMigrationResult memory result) internal {
        address sourceCreditManager = ICreditAccountV3(result.migrationParams.sourceCreditAccount).creditManager();

        _checkSourceUnderlyingIsCollateral(result, sourceCreditManager);

        if (!result.success) {
            return;
        }

        uint256 underlyingRate = _getUnderlyingRate(sourceCreditManager, result.migrationParams.targetCreditManager);

        _populateMigratedCollaterals(result, sourceCreditManager, underlyingRate);
        _populateDebtAndSwapCalls(result, sourceCreditManager, underlyingRate);

        _countCalls(result);

        _checkFailureStates(result);
    }

    /// @dev Checks if the source credit manager underlying is a collateral in the target credit manager.
    ///      If this is not true, the migration is not possible, because it is not possible to convert quotas or convert
    ///      the new underlying into the old one to repay debt.
    function _checkSourceUnderlyingIsCollateral(PreviewMigrationResult memory result, address sourceCreditManager)
        internal
        view
    {
        address sourceUnderlying = ICreditManagerV3(sourceCreditManager).underlying();

        try ICreditManagerV3(result.migrationParams.targetCreditManager).getTokenMaskOrRevert(sourceUnderlying)
        returns (uint256) {} catch {
            result.success = false;
            result.failureStates.sourceUnderlyingIsNotCollateral = true;
        }
    }

    /// @dev Computes the conversion rate of the source CM underlying to the target CM underlying.
    function _getUnderlyingRate(address sourceCreditManager, address targetCreditManager)
        internal
        view
        returns (uint256)
    {
        address targetPriceOracle = ICreditManagerV3(targetCreditManager).priceOracle();

        address sourceUnderlying = ICreditManagerV3(sourceCreditManager).underlying();
        address targetUnderlying = ICreditManagerV3(targetCreditManager).underlying();

        uint256 rate = IPriceOracleV3(targetPriceOracle).convert(WAD, sourceUnderlying, targetUnderlying);

        return rate;
    }

    /// @dev Populates the list of migrated collaterals. This includes the collateral, amount to transfer,
    ///      the required quota in the new credit manager (if needed), as well as phantom token parameters, such as
    ///      the underlying token and the required calls to withdraw and redeposit the phantom token.
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
                sourceCreditManager, result.migrationParams.targetCreditManager, migratedCollaterals[i].collateral
            );

            migratedCollaterals[i].targetQuotaIncrease = _getTargetQuotaIncrease(
                sourceCreditManager, result.migrationParams.sourceCreditAccount, underlyingRate, migratedCollaterals[i]
            );

            migratedCollaterals[i].phantomTokenParams = _getPhantomTokenParams(
                sourceCreditManager,
                result.migrationParams.targetCreditManager,
                migratedCollaterals[i].collateral,
                migratedCollaterals[i].amount
            );

            enabledTokensMask = enabledTokensMask.disable(tokenMask);
        }

        result.migrationParams.migratedCollaterals = migratedCollaterals;
    }

    /// @dev Populates the debt and swap calls. This includes the debt amount to borrow, as well as the calls to swap
    ///      the target CM underlying to the source CM underlying. This also returns the expected underlying dust,
    ///      to optionally swap it back as part of migration extra calls.
    function _populateDebtAndSwapCalls(
        PreviewMigrationResult memory result,
        address sourceCreditManager,
        uint256 underlyingRate
    ) internal {
        address sourceCreditAccount = result.migrationParams.sourceCreditAccount;

        CollateralDebtData memory cdd = ICreditManagerV3(sourceCreditManager).calcDebtAndCollateral(
            sourceCreditAccount, CollateralCalcTask.DEBT_ONLY
        );
        uint256 debtAmount = cdd.calcTotalDebt();

        if (
            ICreditManagerV3(sourceCreditManager).underlying()
                == ICreditManagerV3(result.migrationParams.targetCreditManager).underlying()
        ) {
            result.migrationParams.targetBorrowAmount = debtAmount;
            return;
        }

        result.migrationParams.targetBorrowAmount = debtAmount * underlyingRate * 10100 / (WAD * 10000);

        _computeUnderlyingSwap(result, sourceCreditManager, debtAmount);
    }

    /// @dev Counts the number of calls of each type required to migrate the credit account. This is done to simplify
    ///      computation during actual migration and save gas.
    function _countCalls(PreviewMigrationResult memory result) internal pure {
        for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
            if (result.migrationParams.migratedCollaterals[i].amount > 1) {
                result.migrationParams.numAddCollateralCalls++;
            }
        }

        for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
            if (!result.migrationParams.migratedCollaterals[i].underlyingInSource) {
                result.migrationParams.numRemoveQuotasCalls++;
            }
        }

        for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
            if (result.migrationParams.migratedCollaterals[i].targetQuotaIncrease > 0) {
                result.migrationParams.numIncreaseQuotaCalls++;
            }
        }

        for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
            if (
                result.migrationParams.migratedCollaterals[i].phantomTokenParams.isPhantomToken
                    && result.migrationParams.migratedCollaterals[i].amount > 1
            ) {
                result.migrationParams.numPhantomTokenCalls++;
            }
        }
    }

    /// @dev Checks whether the migration may fail due to various reasons. Also populates the failure states for
    ///      easier display and debugging, as well as the expected HF of the new acount.
    function _checkFailureStates(PreviewMigrationResult memory result) internal view {
        _checkTargetCollaterals(result);

        if (!result.success && result.failureStates.migratedCollateralDoesNotExistInTarget) {
            return;
        }

        _checkTargetQuotaLimits(result);
        _checkNewDebt(result);
        _checkTargetHF(result);
    }

    /// @dev Checks whether the collateral is the underlying of the source or target credit manager.
    function _isCollateralUnderlying(address sourceCreditManager, address targetCreditManager, address collateral)
        internal
        view
        returns (bool isUnderlyingInSource, bool isUnderlyingInTarget)
    {
        isUnderlyingInSource = ICreditManagerV3(sourceCreditManager).underlying() == collateral;
        isUnderlyingInTarget = ICreditManagerV3(targetCreditManager).underlying() == collateral;
    }

    /// @dev Computes the required quota increase in the taregt credit manager. In case when the token is quoted in both source and target,
    ///      the quota is computed by converting the source quota to the target underlying. If the token is not quoted in the source,
    ///      the quota is set to 1.005 of the amount.
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

    /// @dev Computes whether to migrated collateral is a phantom token and populates the phantom token parameters if so.
    ///      This includes the calls to withdraw and redeposit the phantom token. The phantom token may have an override
    ///      to migrate from a deprecated version of a phantom token to a new one. In this case, the underlying and the withdrawal
    ///      call are set in the override.
    function _getPhantomTokenParams(
        address sourceCreditManager,
        address targetCreditManager,
        address collateral,
        uint256 amount
    ) internal view returns (PhantomTokenParams memory ptParams) {
        {
            PhantomTokenOverride memory ptOverride = phantomTokenOverrides[collateral];
            if (ptOverride.newToken != address(0)) {
                ptParams.isPhantomToken = true;
                ptParams.underlying = ptOverride.underlying;

                (address target,) = _getPhantomTokenInfo(collateral);
                address oldAdapter = ICreditManagerV3(sourceCreditManager).contractToAdapter(target);

                ptParams.withdrawalCall = MultiCall({target: oldAdapter, callData: ptOverride.withdrawalCallData});

                address adapter = ICreditManagerV3(targetCreditManager).contractToAdapter(target);
                ptParams.depositCall = MultiCall({
                    target: adapter,
                    callData: abi.encodeCall(IPhantomTokenAdapter.depositPhantomToken, (ptOverride.newToken, amount))
                });

                return ptParams;
            }
        }

        (address target, address depositedToken) = _getPhantomTokenInfo(collateral);
        address newAdapter = ICreditManagerV3(targetCreditManager).contractToAdapter(target);

        ptParams.isPhantomToken = true;
        ptParams.underlying = depositedToken;
        ptParams.depositCall = MultiCall({
            target: newAdapter,
            callData: abi.encodeCall(IPhantomTokenAdapter.depositPhantomToken, (collateral, amount))
        });

        address oldAdapter = ICreditManagerV3(sourceCreditManager).contractToAdapter(target);

        ptParams.withdrawalCall = MultiCall({
            target: oldAdapter,
            callData: abi.encodeCall(IPhantomTokenAdapter.withdrawPhantomToken, (collateral, amount))
        });

        return ptParams;
    }

    /// @dev Computes the underlying swap calls to swap the target CM underlying to the source CM underlying.
    ///      Due to exact output swaps not being supported, the amount borrowed and swapped is taken with a surplus.
    ///      The expected surplus amount is returned in the result, to be optionally swapped back as part of migration extra calls.
    function _computeUnderlyingSwap(
        PreviewMigrationResult memory result,
        address sourceCreditManager,
        uint256 debtAmount
    ) internal {
        uint256 len = ICreditManagerV3(result.migrationParams.targetCreditManager).collateralTokensCount();
        address underlying = ICreditManagerV3(result.migrationParams.targetCreditManager).underlying();

        TokenData[] memory tData = new TokenData[](len);

        for (uint256 i = 0; i < len; ++i) {
            address token = ICreditManagerV3(result.migrationParams.targetCreditManager).getTokenByMask(1 << i);

            tData[i] = TokenData({
                token: token,
                balance: token == underlying ? result.migrationParams.targetBorrowAmount : 0,
                leftoverBalance: 1,
                numSplits: 2,
                claimRewards: false
            });
        }

        try IGearboxRouter(router).routeOpenManyToOne(
            result.migrationParams.targetCreditManager, ICreditManagerV3(sourceCreditManager).underlying(), 50, tData
        ) returns (RouterResult memory routerResult) {
            result.migrationParams.underlyingSwapCalls = routerResult.calls;
            if (routerResult.minAmount < debtAmount) {
                result.success = false;
                result.failureStates.cannotSwapEnoughToCoverDebt = true;
            } else {
                result.expectedUnderlyingDust = routerResult.amount - debtAmount;
            }
        } catch {
            result.success = false;
            result.failureStates.noPathToSourceUnderlying = true;
        }
    }

    /// @dev Checks whether the target pool and credit manager support all of the migrated collaterals.
    function _checkTargetCollaterals(PreviewMigrationResult memory result) internal view {
        address sourceCreditManager = ICreditAccountV3(result.migrationParams.sourceCreditAccount).creditManager();

        address sourcePool = ICreditManagerV3(sourceCreditManager).pool();
        address targetPool = ICreditManagerV3(result.migrationParams.targetCreditManager).pool();

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
            try ICreditManagerV3(result.migrationParams.targetCreditManager).getTokenMaskOrRevert(
                result.migrationParams.migratedCollaterals[i].collateral
            ) returns (uint256) {} catch {
                result.success = false;
                result.failureStates.migratedCollateralDoesNotExistInTarget = true;
            }
        }
    }

    /// @dev Checks whether the target pool and credit manager have enough quotas for the migrated collaterals.
    function _checkTargetQuotaLimits(PreviewMigrationResult memory result) internal view {
        address sourcePool =
            ICreditManagerV3(ICreditAccountV3(result.migrationParams.sourceCreditAccount).creditManager()).pool();
        address targetPool = ICreditManagerV3(result.migrationParams.targetCreditManager).pool();
        address poolQuotaKeeper = IPoolV3(targetPool).poolQuotaKeeper();

        for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
            if (result.migrationParams.migratedCollaterals[i].underlyingInTarget) {
                continue;
            }

            (,,, uint96 totalQuoted, uint96 limit,) = IPoolQuotaKeeperV3(poolQuotaKeeper).getTokenQuotaParams(
                result.migrationParams.migratedCollaterals[i].collateral
            );

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
        }
    }

    /// @dev Checks whether the target pool has sufficient liquidity and limits to cover the new debt.
    function _checkNewDebt(PreviewMigrationResult memory result) internal view {
        address targetPool = ICreditManagerV3(result.migrationParams.targetCreditManager).pool();
        address sourcePool =
            ICreditManagerV3(ICreditAccountV3(result.migrationParams.sourceCreditAccount).creditManager()).pool();

        uint256 creditManagerDebtLimit =
            IPoolV3(targetPool).creditManagerDebtLimit(result.migrationParams.targetCreditManager);
        uint256 creditManagerBorrowed =
            IPoolV3(targetPool).creditManagerBorrowed(result.migrationParams.targetCreditManager);

        if (sourcePool != targetPool) {
            if (result.migrationParams.targetBorrowAmount + creditManagerBorrowed > creditManagerDebtLimit) {
                result.success = false;
                result.failureStates.insufficientTargetDebtLimit = true;
            }
        } else {
            if (creditManagerBorrowed > creditManagerDebtLimit) {
                result.success = false;
                result.failureStates.insufficientTargetDebtLimit = true;
            }
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

    /// @dev Computes the expected HF of the new account and checks whether it is solvent after migration.
    function _checkTargetHF(PreviewMigrationResult memory result) internal view {
        address priceOracle = ICreditManagerV3(result.migrationParams.targetCreditManager).priceOracle();
        address underlying = ICreditManagerV3(result.migrationParams.targetCreditManager).underlying();

        CollateralDebtData memory cdd;

        for (uint256 i = 0; i < result.migrationParams.migratedCollaterals.length; i++) {
            address collateral = result.migrationParams.migratedCollaterals[i].collateral;

            uint16 lt = ICreditManagerV3(result.migrationParams.targetCreditManager).liquidationThresholds(collateral);

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

        cdd.totalDebtUSD =
            IPriceOracleV3(priceOracle).convertToUSD(result.migrationParams.targetBorrowAmount, underlying);

        result.expectedTargetHF = cdd.twvUSD * PERCENTAGE_FACTOR / cdd.totalDebtUSD;

        if (result.expectedTargetHF < 10000) {
            result.success = false;
            result.failureStates.targetHFTooLow = true;
        }
    }

    /// @dev Gets the target and deposited token of a phantom token safely, to account for tokens that may behave
    ///      weirdly on unknown function selector.
    function _getPhantomTokenInfo(address collateral) internal view returns (address target, address depositedToken) {
        (bool success, bytes memory returnData) = OptionalCall.staticCallOptionalSafe({
            target: collateral,
            data: abi.encodeWithSelector(IPhantomToken.getPhantomTokenInfo.selector),
            gasAllowance: 30_000
        });
        if (!success) return (address(0), address(0));

        (target, depositedToken) = abi.decode(returnData, (address, address));
    }

    /// @dev Computes the available liquidity in the pool, taking into account a possible uncrease in available liquidity after
    ///      account closure.
    function _computePoolBorrowableLiquidity(address pool, uint256 liquidityOffset) internal view returns (uint256) {
        uint256 availableLiquidity = IPoolV3(pool).availableLiquidity();
        uint256 expectedLiquidity = IPoolV3(pool).expectedLiquidity();

        address interestRateModel = IPoolV3(pool).interestRateModel();

        return IInterestRateModel(interestRateModel).availableToBorrow(
            expectedLiquidity, availableLiquidity + liquidityOffset
        );
    }

    /// EXECUTION LOGIC

    /// @notice Migrates a credit account from one credit manager to another.
    /// @param params The migration parameters.
    /// @param priceUpdates The price updates to apply.
    function migrateCreditAccount(MigrationParams memory params, PriceUpdate[] memory priceUpdates) external {
        address sourceCreditManager = ICreditAccountV3(params.sourceCreditAccount).creditManager();

        _validateCreditManager(sourceCreditManager);
        _validateCreditManager(params.targetCreditManager);

        _applyPriceUpdates(params.targetCreditManager, priceUpdates);
        _checkAccountOwner(params);

        address creditFacade = ICreditManagerV3(sourceCreditManager).creditFacade();
        address adapter = ICreditManagerV3(sourceCreditManager).contractToAdapter(address(this));

        MultiCall[] memory calls = _getClosingMultiCalls(creditFacade, adapter, params);

        _unlockAdapter(params.sourceCreditAccount, adapter);
        ICreditFacadeV3(creditFacade).botMulticall(params.sourceCreditAccount, calls);
        _lockAdapter(adapter);
    }

    /// @notice Transfer the collaterals from the previous credit account and opens a new credit account with required calls.
    ///         Can only be used when the adapter is unlocked and by the active credit account.
    function migrate(MigrationParams memory params) external {
        if (msg.sender != activeCreditAccount) {
            revert("MigratorBot: caller is not the active credit account");
        }

        uint256 len = params.migratedCollaterals.length;

        for (uint256 i = 0; i < len; i++) {
            address token = params.migratedCollaterals[i].phantomTokenParams.isPhantomToken
                ? params.migratedCollaterals[i].phantomTokenParams.underlying
                : params.migratedCollaterals[i].collateral;

            IERC20(token).safeTransferFrom(msg.sender, address(this), params.migratedCollaterals[i].amount);
            IERC20(token).forceApprove(params.targetCreditManager, params.migratedCollaterals[i].amount);
        }

        address targetCreditFacade = ICreditManagerV3(params.targetCreditManager).creditFacade();

        MultiCall[] memory calls = _getOpeningMultiCalls(targetCreditFacade, params);

        ICreditFacadeV3(targetCreditFacade).openCreditAccount(params.accountOwner, calls, 0);
    }

    /// @dev Checks whether the caller is the owner of the source credit account.
    function _checkAccountOwner(MigrationParams memory params) internal view {
        address sourceCreditManager = ICreditAccountV3(params.sourceCreditAccount).creditManager();
        address sourceAccountOwner =
            ICreditManagerV3(sourceCreditManager).getBorrowerOrRevert(params.sourceCreditAccount);

        if (msg.sender != sourceAccountOwner) {
            revert("MigratorBot: caller is not the account owner");
        }
    }

    /// @dev Builds a MultiCall array to close the source credit account.
    function _getClosingMultiCalls(address creditFacade, address adapter, MigrationParams memory params)
        internal
        pure
        returns (MultiCall[] memory calls)
    {
        uint256 collateralsLength = params.migratedCollaterals.length;

        calls = new MultiCall[](params.numRemoveQuotasCalls + params.numPhantomTokenCalls + 2);
        uint256 k = 0;

        for (uint256 i = 0; i < collateralsLength; i++) {
            if (
                params.migratedCollaterals[i].phantomTokenParams.isPhantomToken
                    && params.migratedCollaterals[i].amount > 1
            ) {
                calls[k++] = params.migratedCollaterals[i].phantomTokenParams.withdrawalCall;
            }
        }

        calls[k++] = MultiCall({target: adapter, callData: abi.encodeCall(IAccountMigratorAdapter.migrate, (params))});

        for (uint256 i = 0; i < collateralsLength; i++) {
            if (!params.migratedCollaterals[i].underlyingInSource) {
                calls[k++] = MultiCall({
                    target: creditFacade,
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.updateQuota, (params.migratedCollaterals[i].collateral, type(int96).min, 0)
                    )
                });
            }
        }

        calls[k] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (type(uint256).max))
        });

        return calls;
    }

    /// @dev Builds a MultiCall array to open the target credit account.
    function _getOpeningMultiCalls(address creditFacade, MigrationParams memory params)
        internal
        view
        returns (MultiCall[] memory calls)
    {
        uint256 collateralsLength = params.migratedCollaterals.length;

        calls = new MultiCall[](
            params.numAddCollateralCalls + params.numIncreaseQuotaCalls + params.numPhantomTokenCalls
                + params.underlyingSwapCalls.length + params.extraOpeningCalls.length + 2
        );

        uint256 k = 0;

        for (uint256 i = 0; i < collateralsLength; i++) {
            if (params.migratedCollaterals[i].amount > 1) {
                address token = params.migratedCollaterals[i].phantomTokenParams.isPhantomToken
                    ? params.migratedCollaterals[i].phantomTokenParams.underlying
                    : params.migratedCollaterals[i].collateral;

                calls[k++] = MultiCall({
                    target: creditFacade,
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.addCollateral, (token, params.migratedCollaterals[i].amount)
                    )
                });
            }
        }

        for (uint256 i = 0; i < collateralsLength; i++) {
            if (
                params.migratedCollaterals[i].phantomTokenParams.isPhantomToken
                    && params.migratedCollaterals[i].amount > 1
            ) {
                calls[k++] = params.migratedCollaterals[i].phantomTokenParams.depositCall;
            }
        }

        for (uint256 i = 0; i < collateralsLength; i++) {
            if (params.migratedCollaterals[i].targetQuotaIncrease > 0) {
                calls[k++] = MultiCall({
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
            }
        }

        uint256 underlyingSwapCallsLength = params.underlyingSwapCalls.length;

        for (uint256 i = 0; i < underlyingSwapCallsLength; i++) {
            calls[k++] = params.underlyingSwapCalls[i];
        }

        calls[k++] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (params.targetBorrowAmount))
        });

        calls[k++] = _getUnderlyingWithdrawCall(creditFacade, params);

        uint256 extraOpeningCallsLength = params.extraOpeningCalls.length;

        for (uint256 i = 0; i < extraOpeningCallsLength; i++) {
            calls[k++] = params.extraOpeningCalls[i];
        }
    }

    /// @dev Builds a call to withdraw an amount of underlying equal to the source account's debt.
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

    /// @dev Computes the total debt of a credit account.
    function _getAccountTotalDebt(address creditAccount) internal view returns (uint256) {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();

        CollateralDebtData memory cdd =
            ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);

        return cdd.calcTotalDebt();
    }

    /// @dev Applies the price updates for push price feeds.
    function _applyPriceUpdates(address creditManager, PriceUpdate[] memory priceUpdates) internal {
        address creditFacade = ICreditManagerV3(creditManager).creditFacade();
        address priceFeedStore = ICreditFacadeV3(creditFacade).priceFeedStore();

        IPriceFeedStore(priceFeedStore).updatePrices(priceUpdates);
    }

    /// @dev Unlocks the account migration adapter.
    function _unlockAdapter(address creditAccount, address adapter) internal {
        activeCreditAccount = creditAccount;
        IAccountMigratorAdapter(adapter).unlock();
    }

    /// @dev Locks the account migration adapter.
    function _lockAdapter(address adapter) internal {
        activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;
        IAccountMigratorAdapter(adapter).lock();
    }

    /// @dev Validates that the credit manager is known by Gearbox protocol.
    function _validateCreditManager(address creditManager) internal view {
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        address acl = ACLTrait(creditConfigurator).acl();
        address mc = Ownable(acl).owner();

        address contractsRegister = IMarketConfigurator(mc).contractsRegister();

        if (
            !IMarketConfiguratorFactory(mcFactory).isMarketConfigurator(mc)
                || !IContractsRegister(contractsRegister).isCreditManager(creditManager)
        ) {
            revert("MigratorBot: credit manager is not valid");
        }
    }

    function serialize() external view override returns (bytes memory) {
        address[] memory overridenPhantomTokens = _overridenPhantomTokens.values();

        PhantomTokenOverride[] memory ptOverrides = new PhantomTokenOverride[](overridenPhantomTokens.length);

        for (uint256 i = 0; i < overridenPhantomTokens.length; i++) {
            ptOverrides[i] = phantomTokenOverrides[overridenPhantomTokens[i]];
        }

        return abi.encode(mcFactory, router, ptOverrides);
    }

    function setPhantomTokenOverride(
        address phantomToken,
        address newToken,
        address underlying,
        bytes calldata withdrawalCallData
    ) external onlyOwner {
        phantomTokenOverrides[phantomToken] =
            PhantomTokenOverride({newToken: newToken, underlying: underlying, withdrawalCallData: withdrawalCallData});

        _overridenPhantomTokens.add(phantomToken);
    }
}
