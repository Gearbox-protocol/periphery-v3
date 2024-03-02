// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

import "@gearbox-protocol/core-v3/contracts/interfaces/IAddressProviderV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {PERCENTAGE_FACTOR, RAY} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";
import {IContractsRegister} from "@gearbox-protocol/core-v2/contracts/interfaces/IContractsRegister.sol";
import {CreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/credit/CreditFacadeV3.sol";

import {
    ICreditManagerV3,
    CollateralDebtData,
    CollateralCalcTask
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {PoolV3} from "@gearbox-protocol/core-v3/contracts/pool/PoolV3.sol";

import {CreditManagerV3} from "@gearbox-protocol/core-v3/contracts/credit/CreditManagerV3.sol";

import {CreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/credit/CreditFacadeV3.sol";
import {IBotListV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IBotListV3.sol";
import {IGaugeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IGaugeV3.sol";

import {IPriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";
import {IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {IDataCompressorV3, PriceOnDemand} from "../interfaces/IDataCompressorV3.sol";
import {IZapper} from "@gearbox-protocol/integrations-v3/contracts/interfaces/zappers/IZapper.sol";

import {
    COUNT,
    QUERY,
    CreditAccountData,
    CreditManagerData,
    PoolData,
    TokenBalance,
    ContractAdapter,
    QuotaInfo,
    GaugeInfo,
    GaugeQuotaParams,
    CreditManagerDebtParams,
    ZapperInfo,
    LinearModel
} from "./Types.sol";

// EXCEPTIONS
import "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {LinearInterestModelHelper} from "./LinearInterestModelHelper.sol";
import {IZapperRegister} from "../interfaces/IZapperRegister.sol";

import "forge-std/console.sol";

/// @title Data compressor 3.0.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
contract DataCompressorV3 is IDataCompressorV3, ContractsRegisterTrait, LinearInterestModelHelper {
    // Contract version
    uint256 public constant version = 3_00;

    IZapperRegister public zapperRegister;

    error CreditManagerIsNotV3Exception();

    constructor(address _addressProvider) ContractsRegisterTrait(_addressProvider) {
        zapperRegister =
            IZapperRegister(IAddressProviderV3(_addressProvider).getAddressOrRevert("ZAPPER_REGISTER", 3_00));
    }

    /// @dev Returns CreditAccountData for all opened accounts for particular borrower
    /// @param borrower Borrower address
    /// @param priceUpdates Price updates for priceFeedsOnDemand
    function getCreditAccountsByBorrower(address borrower, PriceOnDemand[] memory priceUpdates)
        external
        override
        returns (CreditAccountData[] memory result)
    {
        return _queryCreditAccounts(_listCreditManagersV3(), borrower, false, priceUpdates);
    }

    function getCreditAccountsByCreditManager(address creditManager, PriceOnDemand[] memory priceUpdates)
        external
        override
        registeredCreditManagerOnly(creditManager)
        returns (CreditAccountData[] memory result)
    {
        if (!_isContractV3(creditManager)) revert CreditManagerIsNotV3Exception();

        address[] memory creditManagers = new address[](1);
        creditManagers[0] = creditManager;
        return _queryCreditAccounts(creditManagers, address(0), false, priceUpdates);
    }

    function getLiquidatableCreditAccounts(PriceOnDemand[] memory priceUpdates)
        external
        override
        returns (CreditAccountData[] memory result)
    {
        return _queryCreditAccounts(_listCreditManagersV3(), address(0), true, priceUpdates);
    }

    /// @notice Query credit accounts data by parameters
    /// @param borrower Borrower address, all borrowers if address(0)
    /// @param liquidatableOnly If true, returns only liquidatable accounts
    /// @param priceUpdates Price updates for priceFeedsOnDemand
    function _queryCreditAccounts(
        address[] memory creditManagers,
        address borrower,
        bool liquidatableOnly,
        PriceOnDemand[] memory priceUpdates
    ) internal returns (CreditAccountData[] memory result) {
        uint256 index;
        uint256 len = creditManagers.length;
        unchecked {
            for (uint256 op = COUNT; op <= QUERY; ++op) {
                if (op == QUERY && index == 0) break;

                result = new CreditAccountData[](index);
                index = 0;
                for (uint256 i = 0; i < len; ++i) {
                    address _cm = creditManagers[i];

                    _updatePrices(_cm, priceUpdates);
                    address[] memory creditAccounts = ICreditManagerV3(_cm).creditAccounts();
                    uint256 caLen = creditAccounts.length;
                    for (uint256 j; j < caLen; ++j) {
                        if (borrower != address(0) && borrower != _getBorrowerOrRevert(_cm, creditAccounts[j])) {
                            continue;
                        }

                        if (liquidatableOnly) {
                            try ICreditManagerV3(_cm).isLiquidatable(creditAccounts[j], PERCENTAGE_FACTOR) returns (
                                bool isLiquidatable
                            ) {
                                if (!isLiquidatable) continue;
                            } catch {}
                        }

                        if (op == QUERY) result[index] = _getCreditAccountData(_cm, creditAccounts[j]);
                        ++index;
                    }
                }
            }
        }
    }

    /// @dev Returns CreditAccountData for a particular Credit Account account, based on creditManager and borrower
    /// @param _creditAccount Credit account address
    /// @param priceUpdates Price updates for priceFeedsOnDemand
    function getCreditAccountData(address _creditAccount, PriceOnDemand[] memory priceUpdates)
        public
        returns (CreditAccountData memory result)
    {
        ICreditAccountV3 creditAccount = ICreditAccountV3(_creditAccount);

        address _cm = creditAccount.creditManager();
        _ensureRegisteredCreditManager(_cm);

        if (!_isContractV3(_cm)) revert CreditManagerIsNotV3Exception();

        _updatePrices(_cm, priceUpdates);

        return _getCreditAccountData(_cm, _creditAccount);
    }

    function _getCreditAccountData(address _cm, address _creditAccount)
        internal
        view
        returns (CreditAccountData memory result)
    {
        ICreditManagerV3 creditManager = ICreditManagerV3(_cm);
        ICreditFacadeV3 creditFacade = _getCreditFacade(address(creditManager));
        // ICreditConfiguratorV3 creditConfigurator = ICreditConfiguratorV3(creditManager.creditConfigurator());
        result.creditFacade = address(creditFacade);
        result.cfVersion = _getVersion(address(creditFacade));

        address borrower = _getBorrowerOrRevert(address(creditManager), _creditAccount);

        result.borrower = borrower;
        result.creditManager = _cm;
        result.addr = _creditAccount;

        result.underlying = _getUnderlying(creditManager);
        result.cmName = _getName(_cm);

        address pool = _getPool(_cm);
        result.baseBorrowRate = _getBaseInterestRate(pool);

        uint256 collateralTokenCount = _getCollateralTokensCount(address(creditManager));

        result.enabledTokensMask = creditManager.enabledTokensMaskOf(_creditAccount);

        result.balances = new TokenBalance[](collateralTokenCount);

        uint256 quotaRevenue = 0;
        {
            uint256 forbiddenTokenMask = creditFacade.forbiddenTokenMask();
            uint256 quotedTokensMask = creditManager.quotedTokensMask();
            IPoolQuotaKeeperV3 pqk = _getPoolQuotaKeeper(pool);

            unchecked {
                for (uint256 i = 0; i < collateralTokenCount; ++i) {
                    TokenBalance memory balance;
                    uint256 tokenMask = 1 << i;

                    (balance.token,) = creditManager.collateralTokenByMask(tokenMask);
                    balance.balance = IERC20(balance.token).balanceOf(_creditAccount);

                    balance.isForbidden = tokenMask & forbiddenTokenMask == 0 ? false : true;
                    balance.isEnabled = tokenMask & result.enabledTokensMask == 0 ? false : true;

                    balance.isQuoted = tokenMask & quotedTokensMask == 0 ? false : true;

                    if (balance.isQuoted) {
                        (balance.quota, balance.quotaCumulativeIndexLU) = pqk.getQuota(_creditAccount, balance.token);
                        balance.quotaRate = pqk.getQuotaRate(balance.token);

                        quotaRevenue += balance.quota * balance.quotaRate;
                    }

                    result.balances[i] = balance;
                }
            }
        }

        result.aggregatedBorrowRate =
            result.baseBorrowRate + (result.debt == 0 ? 0 : RAY * quotaRevenue / PERCENTAGE_FACTOR / result.debt);

        // uint256 debt;
        // uint256 cumulativeIndexNow;
        // uint256 cumulativeIndexLastUpdate;
        // uint128 cumulativeQuotaInterest;
        // uint256 accruedInterest;
        // uint256 accruedFees;
        // uint256 totalDebtUSD;
        // uint256 totalValue;
        // uint256 totalValueUSD;
        // uint256 twvUSD;
        // uint256 enabledTokensMask;
        // uint256 quotedTokensMask;
        // address[] quotedTokens;

        for (uint256 i = 0; i < 2;) {
            try creditManager.calcDebtAndCollateral(
                _creditAccount, i == 0 ? CollateralCalcTask.DEBT_ONLY : CollateralCalcTask.DEBT_COLLATERAL
            ) returns (CollateralDebtData memory collateralDebtData) {
                result.accruedInterest = collateralDebtData.accruedInterest;
                result.accruedFees = collateralDebtData.accruedFees;

                result.totalDebtUSD = collateralDebtData.totalDebtUSD;
                result.totalValueUSD = collateralDebtData.totalValueUSD;
                result.twvUSD = collateralDebtData.twvUSD;
                result.healthFactor = collateralDebtData.totalDebtUSD != 0
                    ? collateralDebtData.twvUSD * PERCENTAGE_FACTOR / collateralDebtData.totalDebtUSD
                    : type(uint16).max;
                result.totalValue = collateralDebtData.totalValue;
                result.isSuccessful = true;
            } catch {
                result.priceFeedsNeeded = _getPriceFeedFailedList(_cm, result.balances);
                result.isSuccessful = false;
            }

            unchecked {
                ++i;
            }
        }

        (result.debt, result.cumulativeIndexLastUpdate, result.cumulativeQuotaInterest,,,, result.since,) =
            CreditManagerV3(_cm).creditAccountInfo(_creditAccount);

        result.expirationDate = creditFacade.expirationDate();

        result.activeBots = IBotListV3(CreditFacadeV3(address(creditFacade)).botList()).activeBots(_cm, _creditAccount);
    }

    function _listCreditManagersV3() internal view returns (address[] memory result) {
        uint256 len = IContractsRegister(contractsRegister).getCreditManagersCount();

        uint256 index;
        unchecked {
            for (uint256 op = COUNT; op <= QUERY; ++op) {
                if (op == QUERY && index == 0) {
                    break;
                } else {
                    result = new address[](index);
                    index = 0;
                }

                for (uint256 i = 0; i < len; ++i) {
                    address _cm = IContractsRegister(contractsRegister).creditManagers(i);

                    if (_isContractV3(_cm)) {
                        if (op == QUERY) result[index] = _cm;
                        ++index;
                    }
                }
            }
        }
    }

    function _isContractV3(address _cm) internal view returns (bool) {
        uint256 cmVersion = _getVersion(_cm);
        return cmVersion >= 3_00 && cmVersion < 3_99;
    }

    /// @dev Returns CreditManagerData for all Credit Managers
    function getCreditManagersV3List() external view returns (CreditManagerData[] memory result) {
        address[] memory creditManagers = _listCreditManagersV3();
        uint256 len = creditManagers.length;

        result = new CreditManagerData[](len);

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                result[i] = getCreditManagerData(creditManagers[i]);
            }
        }
    }

    /// @dev Returns CreditManagerData for a particular _cm
    /// @param _cm CreditManager address
    function getCreditManagerData(address _cm) public view returns (CreditManagerData memory result) {
        ICreditManagerV3 creditManager = ICreditManagerV3(_cm);
        ICreditConfiguratorV3 creditConfigurator = ICreditConfiguratorV3(creditManager.creditConfigurator());
        ICreditFacadeV3 creditFacade = _getCreditFacade(address(creditManager));

        result.addr = _cm;
        result.name = _getName(_cm);
        result.cfVersion = _getVersion(address(creditFacade));

        result.creditFacade = address(creditFacade);
        result.creditConfigurator = address(creditConfigurator);

        result.underlying = _getUnderlying(creditManager);

        {
            result.pool = _getPool(_cm);
            IPoolV3 pool = IPoolV3(result.pool);
            result.totalDebt = pool.creditManagerBorrowed(_cm);
            result.totalDebtLimit = pool.creditManagerDebtLimit(_cm);

            result.baseBorrowRate = _getBaseInterestRate(address(pool));
            result.availableToBorrow = pool.creditManagerBorrowable(_cm);
            result.lirm = _getInterestRateModel(address(pool));
        }

        (result.minDebt, result.maxDebt) = creditFacade.debtLimits();

        {
            uint256 collateralTokenCount = _getCollateralTokensCount(address(creditManager));

            result.collateralTokens = new address[](collateralTokenCount);
            result.liquidationThresholds = new uint256[](collateralTokenCount);

            unchecked {
                for (uint256 i = 0; i < collateralTokenCount; ++i) {
                    (result.collateralTokens[i], result.liquidationThresholds[i]) =
                        creditManager.collateralTokenByMask(1 << i);
                }
            }
        }

        address[] memory allowedAdapters = creditConfigurator.allowedAdapters();
        uint256 len = allowedAdapters.length;
        result.adapters = new ContractAdapter[](len);

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address allowedAdapter = allowedAdapters[i];

                result.adapters[i] = ContractAdapter({
                    targetContract: creditManager.adapterToContract(allowedAdapter),
                    adapter: allowedAdapter
                });
            }
        }

        result.degenNFT = creditFacade.degenNFT();
        result.isDegenMode = result.degenNFT != address(0);
        // (, result.isIncreaseDebtForbidden,,) = creditFacade.params(); // V2 only: true if increasing debt is forbidden
        result.forbiddenTokenMask = creditFacade.forbiddenTokenMask(); // V2 only: mask which forbids some particular tokens
        result.maxEnabledTokensLength = creditManager.maxEnabledTokens(); // V2 only: a limit on enabled tokens imposed for security
        {
            (
                result.feeInterest,
                result.feeLiquidation,
                result.liquidationDiscount,
                result.feeLiquidationExpired,
                result.liquidationDiscountExpired
            ) = creditManager.fees();
        }

        result.quotas = _getQuotas(result.pool);

        result.isPaused = _getPaused(address(creditFacade));
    }

    /// @dev Returns PoolData for a particular pool
    /// @param _pool Pool address
    function getPoolData(address _pool) public view registeredPoolOnly(_pool) returns (PoolData memory result) {
        PoolV3 pool = PoolV3(_pool);

        result.addr = _pool;
        result.expectedLiquidity = pool.expectedLiquidity();
        result.availableLiquidity = pool.availableLiquidity();

        result.dieselRate_RAY = pool.convertToAssets(RAY);
        result.baseInterestIndex = pool.baseInterestIndex();
        result.baseInterestRate = _getBaseInterestRate(address(pool));
        result.underlying = pool.underlyingToken();
        result.dieselToken = address(pool);
        (result.symbol, result.name) = _getSymbolAndName(_pool);

        result.dieselRate_RAY = pool.convertToAssets(RAY);
        result.withdrawFee = pool.withdrawFee();
        result.baseInterestIndexLU = pool.baseInterestIndexLU();
        result.lastBaseInterestUpdate = pool.lastBaseInterestUpdate();
        // result.cumulativeIndex_RAY = pool.calcLinearCumulative_RAY();

        // Borrowing limits
        result.totalBorrowed = pool.totalBorrowed();
        result.totalDebtLimit = pool.totalDebtLimit();

        address[] memory creditManagers = pool.creditManagers();
        uint256 len = creditManagers.length;
        result.creditManagerDebtParams = new CreditManagerDebtParams[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                address creditManager = creditManagers[i];
                result.creditManagerDebtParams[i] = CreditManagerDebtParams({
                    creditManager: creditManager,
                    borrowed: pool.creditManagerBorrowed(creditManager),
                    limit: pool.creditManagerDebtLimit(creditManager),
                    availableToBorrow: pool.creditManagerBorrowable(creditManager)
                });
            }
        }

        result.totalSupply = pool.totalSupply();
        result.totalAssets = pool.totalAssets();
        result.supplyRate = pool.supplyRate();

        result.version = _getVersion(address(pool));

        result.quotas = _getQuotas(_pool);
        result.lirm = _getInterestRateModel(_pool);
        result.isPaused = _getPaused(_pool);

        // Adding zappers
        address[] memory zappers = zapperRegister.zappers(address(pool));
        len = zappers.length;
        result.zappers = new ZapperInfo[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                address tokenIn = IZapper(zappers[i]).tokenIn();
                address tokenOut = IZapper(zappers[i]).tokenOut();
                result.zappers[i] = ZapperInfo({tokenIn: tokenIn, tokenOut: tokenOut, zapper: zappers[i]});
            }
        }

        result.poolQuotaKeeper = address(_getPoolQuotaKeeper(_pool));
        result.gauge = _getGauge(IPoolQuotaKeeperV3(result.poolQuotaKeeper));

        return result;
    }

    /// @dev Returns PoolData for all registered pools
    function getPoolsV3List() external view returns (PoolData[] memory result) {
        address[] memory poolsV3 = _listPoolsV3();
        uint256 len = poolsV3.length;
        result = new PoolData[](len);

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                result[i] = getPoolData(poolsV3[i]);
            }
        }
    }

    function _listPoolsV3() internal view returns (address[] memory result) {
        uint256 len = IContractsRegister(contractsRegister).getPoolsCount();

        uint256 index;
        unchecked {
            for (uint256 op = COUNT; op <= QUERY; ++op) {
                if (op == QUERY && index == 0) {
                    break;
                } else {
                    result = new address[](index);
                    index = 0;
                }

                for (uint256 i = 0; i < len; ++i) {
                    address _pool = IContractsRegister(contractsRegister).pools(i);

                    if (_isContractV3(_pool)) {
                        if (op == QUERY) result[index] = _pool;
                        ++index;
                    }
                }
            }
        }
    }

    function _updatePrices(address creditManager, PriceOnDemand[] memory priceUpdates) internal {
        uint256 len = priceUpdates.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                address priceFeed = _getPriceOracle(creditManager).priceFeeds(priceUpdates[i].token);
                if (priceFeed == address(0)) revert PriceFeedDoesNotExistException();

                IUpdatablePriceFeed(priceFeed).updatePrice(priceUpdates[i].callData);
            }
        }
    }

    function _getPriceFeedFailedList(address _cm, TokenBalance[] memory balances)
        internal
        view
        returns (address[] memory priceFeedFailed)
    {
        uint256 len = balances.length;

        IPriceOracleV3 priceOracle = _getPriceOracle(_cm);

        uint256 index;

        /// It counts on the first iteration how many price feeds failed and then fill the array on the second iteration
        for (uint256 op = COUNT; op <= QUERY; ++op) {
            if (op == QUERY && index == 0) {
                break;
            } else {
                priceFeedFailed = new address[](index);
                index = 0;
            }
            unchecked {
                for (uint256 i = 0; i < len; ++i) {
                    TokenBalance memory balance = balances[i];

                    if (balance.balance > 1 && balance.isEnabled) {
                        try priceOracle.getPrice(balance.token) returns (uint256) {}
                        catch {
                            if (op == QUERY) priceFeedFailed[index] = balance.token;
                            ++index;
                        }
                    }
                }
            }
        }
    }

    function _getPoolQuotaKeeper(address pool) internal view returns (IPoolQuotaKeeperV3) {
        return IPoolQuotaKeeperV3(IPoolV3(pool).poolQuotaKeeper());
    }

    function _getPriceOracle(address _cm) internal view returns (IPriceOracleV3) {
        return IPriceOracleV3(ICreditManagerV3(_cm).priceOracle());
    }

    function _getBaseInterestRate(address pool) internal view returns (uint256) {
        return IPoolV3(pool).baseInterestRate();
    }

    function _getBorrowerOrRevert(address cm, address creditAccount) internal view returns (address) {
        return ICreditManagerV3(cm).getBorrowerOrRevert(creditAccount);
    }

    function _getVersion(address versionedContract) internal view returns (uint256) {
        return IVersion(versionedContract).version();
    }

    function _getCreditFacade(address cm) internal view returns (ICreditFacadeV3) {
        return ICreditFacadeV3(ICreditManagerV3(cm).creditFacade());
    }

    function _getSymbolAndName(address token) internal view returns (string memory symbol, string memory name) {
        symbol = IERC20Metadata(token).symbol();
        name = _getName(token);
    }

    function _getInterestRateModel(address pool) internal view returns (LinearModel memory) {
        return getLIRMData(IPoolV3(pool).interestRateModel());
    }

    function _getQuotedTokens(IPoolQuotaKeeperV3 pqk) internal view returns (address[] memory result) {
        result = pqk.quotedTokens();
    }

    function _getPool(address cnt) internal view returns (address) {
        return ICreditManagerV3(cnt).pool();
    }

    function _getName(address _cm) internal view returns (string memory) {
        return IERC20Metadata(_cm).name();
    }

    function _getCollateralTokensCount(address _cm) internal view returns (uint256) {
        return ICreditManagerV3(_cm).collateralTokensCount();
    }

    function _getGauge(IPoolQuotaKeeperV3 pqk) internal view returns (address) {
        return pqk.gauge();
    }

    function _getPaused(address pausableContract) internal view returns (bool) {
        return Pausable(pausableContract).paused();
    }

    function _getUnderlying(ICreditManagerV3 cm) internal view returns (address) {
        return cm.underlying();
    }

    function _getQuotas(address _pool) internal view returns (QuotaInfo[] memory quotas) {
        IPoolQuotaKeeperV3 pqk = _getPoolQuotaKeeper(_pool);

        address[] memory quotaTokens = _getQuotedTokens(pqk);
        uint256 len = quotaTokens.length;
        quotas = new QuotaInfo[](len);
        unchecked {
            for (uint256 i; i < len; ++i) {
                quotas[i].token = quotaTokens[i];
                (
                    quotas[i].rate,
                    ,
                    quotas[i].quotaIncreaseFee,
                    quotas[i].totalQuoted,
                    quotas[i].limit,
                    quotas[i].isActive
                ) = pqk.getTokenQuotaParams(quotaTokens[i]);
            }
        }
    }

    function getGaugesV3Data(address staker) external view override returns (GaugeInfo[] memory result) {
        address[] memory poolsV3 = _listPoolsV3();
        uint256 len = poolsV3.length;
        result = new GaugeInfo[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                GaugeInfo memory gaugeInfo = result[i];
                IPoolQuotaKeeperV3 pqk = _getPoolQuotaKeeper(poolsV3[i]);
                address gauge = _getGauge(pqk);
                gaugeInfo.addr = gauge;
                gaugeInfo.pool = _getPool(gauge);
                (gaugeInfo.symbol, gaugeInfo.name) = _getSymbolAndName(gaugeInfo.pool);
                gaugeInfo.underlying = IPoolV3(gaugeInfo.pool).asset();

                address[] memory quotaTokens = _getQuotedTokens(pqk);
                uint256 quotaTokensLen = quotaTokens.length;
                gaugeInfo.quotaParams = new GaugeQuotaParams[](quotaTokensLen);

                gaugeInfo.currentEpoch = IGaugeV3(gauge).epochLastUpdate();
                gaugeInfo.epochFrozen = IGaugeV3(gauge).epochFrozen();

                for (uint256 j; j < quotaTokensLen; ++j) {
                    GaugeQuotaParams memory quotaParams = gaugeInfo.quotaParams[j];
                    address token = quotaTokens[j];
                    quotaParams.token = token;

                    (
                        quotaParams.rate,
                        ,
                        quotaParams.quotaIncreaseFee,
                        quotaParams.totalQuoted,
                        quotaParams.limit,
                        quotaParams.isActive
                    ) = pqk.getTokenQuotaParams(token);

                    (
                        quotaParams.minRate,
                        quotaParams.maxRate,
                        quotaParams.totalVotesLpSide,
                        quotaParams.totalVotesCaSide
                    ) = IGaugeV3(gauge).quotaRateParams(token);

                    (quotaParams.stakerVotesLpSide, quotaParams.stakerVotesCaSide) =
                        IGaugeV3(gauge).userTokenVotes(staker, token);
                }
            }
        }
    }
}
