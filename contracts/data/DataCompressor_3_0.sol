// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {IWithdrawalManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IWithdrawalManagerV3.sol";
import {IGaugeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IGaugeV3.sol";

import {IPriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";
import {IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {IDataCompressorV3_00, PriceOnDemand} from "../interfaces/IDataCompressorV3_00.sol";

import {
    CreditAccountData,
    CreditManagerData,
    PoolData,
    TokenBalance,
    ContractAdapter,
    QuotaInfo,
    GaugeInfo,
    GaugeQuotaParams,
    CreditManagerDebtParams,
    GaugeVote
} from "./Types.sol";

// EXCEPTIONS
import "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {LinearInterestModelHelper} from "./LinearInterestModelHelper.sol";

uint256 constant COUNT = 0;
uint256 constant QUERY = 1;

/// @title Data compressor 3.0.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
contract DataCompressorV3_00 is IDataCompressorV3_00, ContractsRegisterTrait, LinearInterestModelHelper {
    // Contract version
    uint256 public constant version = 3_00;

    error CreditManagerIsNotV3Exception();

    constructor(address _addressProvider) ContractsRegisterTrait(_addressProvider) {}

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
                if (op == QUERY && index == 0) {
                    break;
                } else {
                    result = new CreditAccountData[](index);
                    index = 0;
                }

                for (uint256 i = 0; i < len; ++i) {
                    address _pool = creditManagers[i];

                    _updatePrices(_pool, priceUpdates);
                    address[] memory creditAccounts = ICreditManagerV3(_pool).creditAccounts();
                    uint256 caLen = creditAccounts.length;
                    for (uint256 j; j < caLen; ++j) {
                        if (
                            (
                                borrower == address(0)
                                    || ICreditManagerV3(_pool).getBorrowerOrRevert(creditAccounts[i]) == borrower
                            )
                                && (
                                    !liquidatableOnly
                                        || ICreditManagerV3(_pool).isLiquidatable(creditAccounts[i], PERCENTAGE_FACTOR)
                                )
                        ) {
                            if (op == QUERY) {
                                result[index] = _getCreditAccountData(_pool, creditAccounts[j]);
                            }
                            ++index;
                        }
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

        address _pool = creditAccount.creditManager();
        _ensureRegisteredCreditManager(_pool);

        if (!_isContractV3(_pool)) revert CreditManagerIsNotV3Exception();

        _updatePrices(_pool, priceUpdates);

        return _getCreditAccountData(_pool, _creditAccount);
    }

    function _getCreditAccountData(address _pool, address _creditAccount)
        internal
        view
        returns (CreditAccountData memory result)
    {
        ICreditManagerV3 creditManager = ICreditManagerV3(_pool);
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(creditManager.creditFacade());
        // ICreditConfiguratorV3 creditConfigurator = ICreditConfiguratorV3(creditManager.creditConfigurator());

        result.cfVersion = creditFacade.version();

        address borrower = creditManager.getBorrowerOrRevert(_creditAccount);

        result.borrower = borrower;
        result.creditManager = _pool;
        result.addr = _creditAccount;

        result.underlying = creditManager.underlying();

        address pool = creditManager.pool();
        result.baseBorrowRate = IPoolV3(pool).baseInterestRate();

        uint256 collateralTokenCount = creditManager.collateralTokensCount();

        result.enabledTokensMask = creditManager.enabledTokensMaskOf(_creditAccount);

        result.balances = new TokenBalance[](collateralTokenCount);
        {
            uint256 forbiddenTokenMask = creditFacade.forbiddenTokenMask();
            uint256 quotedTokensMask = creditManager.quotedTokensMask();
            IPoolQuotaKeeperV3 pqk = IPoolQuotaKeeperV3(creditManager.poolQuotaKeeper());

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
                        (balance.quota,) = pqk.getQuota(_creditAccount, balance.token);
                        balance.quotaRate = pqk.getQuotaRate(balance.token);
                    }

                    result.balances[i] = balance;
                }
            }
        }

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

        try creditManager.calcDebtAndCollateral(_creditAccount, CollateralCalcTask.DEBT_COLLATERAL_WITHOUT_WITHDRAWALS)
        returns (CollateralDebtData memory collateralDebtData) {
            result.accruedInterest = collateralDebtData.accruedInterest;
            result.accruedFees = collateralDebtData.accruedFees;
            result.healthFactor = collateralDebtData.twvUSD * PERCENTAGE_FACTOR / collateralDebtData.debt;
            result.totalValue = collateralDebtData.totalValue;
            result.isSuccessful = true;
        } catch {
            _getPriceFeedFailedList(_pool, result.balances);
            result.isSuccessful = false;
        }

        // (result.totalValue,) = creditFacade.calcTotalValue(creditAccount);
        //  = ICreditAccountV3(creditAccount).cumulativeIndexAtOpen();

        // uint256 debt;
        // uint256 cumulativeIndexLastUpdate;
        // uint128 cumulativeQuotaInterest;
        // uint128 quotaFees;
        // uint256 enabledTokensMask;
        // uint16 flags;
        // uint64 since;
        // address borrower;

        (result.debt, result.cumulativeIndexLastUpdate, result.cumulativeQuotaInterest,,,, result.since,) =
            CreditManagerV3(_pool).creditAccountInfo(_creditAccount);

        result.expirationDate = creditFacade.expirationDate();
        result.maxApprovedBots = CreditFacadeV3(address(creditFacade)).maxApprovedBots();

        result.activeBots =
            IBotListV3(CreditFacadeV3(address(creditFacade)).botList()).getActiveBots(_pool, _creditAccount);

        // QuotaInfo[] quotas;
        result.schedultedWithdrawals = IWithdrawalManagerV3(CreditFacadeV3(address(creditFacade)).withdrawalManager())
            .scheduledWithdrawals(_creditAccount);
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
                    address _pool = IContractsRegister(contractsRegister).creditManagers(i);

                    if (_isContractV3(_pool)) {
                        if (op == QUERY) result[index] = _pool;
                        ++index;
                    }
                }
            }
        }
    }

    function _isContractV3(address _pool) internal view returns (bool) {
        uint256 cmVersion = IVersion(_pool).version();
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

    /// @dev Returns CreditManagerData for a particular _pool
    /// @param _pool CreditManager address
    function getCreditManagerData(address _pool) public view returns (CreditManagerData memory result) {
        ICreditManagerV3 creditManager = ICreditManagerV3(_pool);
        ICreditConfiguratorV3 creditConfigurator = ICreditConfiguratorV3(creditManager.creditConfigurator());
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(creditManager.creditFacade());

        result.addr = _pool;
        result.cfVersion = creditFacade.version();

        result.underlying = creditManager.underlying();

        {
            result.pool = creditManager.pool();
            IPoolV3 pool = IPoolV3(result.pool);
            result.baseBorrowRate = pool.baseInterestRate();
            result.availableToBorrow = pool.creditManagerBorrowable(_pool);
            result.lirm = getLIRMData(pool.interestRateModel());
        }

        (result.minDebt, result.maxDebt) = creditFacade.debtLimits();

        {
            uint256 collateralTokenCount = creditManager.collateralTokensCount();

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

        result.creditFacade = address(creditFacade);
        result.creditConfigurator = address(creditConfigurator);
        result.degenNFT = creditFacade.degenNFT();
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

        result.isPaused = CreditFacadeV3(address(creditFacade)).paused();
    }

    /// @dev Returns PoolData for a particular pool
    /// @param _pool Pool address
    function getPoolData(address _pool) public view registeredPoolOnly(_pool) returns (PoolData memory result) {
        PoolV3 pool = PoolV3(_pool);

        result.addr = _pool;
        result.expectedLiquidity = pool.expectedLiquidity();
        result.availableLiquidity = pool.availableLiquidity();

        result.dieselRate_RAY = pool.convertToAssets(RAY);
        result.linearCumulativeIndex = pool.calcLinearCumulative_RAY();
        result.baseInterestRate = pool.baseInterestRate();
        result.underlying = pool.underlyingToken();
        result.dieselToken = address(pool);

        result.dieselRate_RAY = pool.convertToAssets(RAY);
        result.withdrawFee = pool.withdrawFee();
        result.baseInterestIndexLU = pool.baseInterestIndexLU();
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

        result.version = uint8(pool.version());

        result.quotas = _getQuotas(_pool);
        result.lirm = getLIRMData(pool.interestRateModel());
        result.isPaused = pool.paused();

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
                address priceFeed =
                    IPriceOracleV3(ICreditManagerV3(creditManager).priceOracle()).priceFeeds(priceUpdates[i].token);
                if (priceFeed == address(0)) revert PriceFeedDoesNotExistException();

                IUpdatablePriceFeed(priceFeed).updatePrice(priceUpdates[i].callData);
            }
        }
    }

    function _getPriceFeedFailedList(address _pool, TokenBalance[] memory balances)
        internal
        view
        returns (address[] memory priceFeedFailed)
    {
        uint256 len = balances.length;

        IPriceOracleV3 priceOracle = IPriceOracleV3(ICreditManagerV3(_pool).priceOracle());

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
                        try IPriceFeed(priceOracle.priceFeeds(balance.token)).latestRoundData() returns (
                            uint80, int256, uint256, uint256, uint80
                        ) {} catch {
                            if (op == QUERY) priceFeedFailed[index] = balance.token;
                            ++index;
                        }
                    }
                }
            }
        }
    }

    function _getQuotas(address _pool) internal view returns (QuotaInfo[] memory quotas) {
        IPoolQuotaKeeperV3 pqk = IPoolQuotaKeeperV3(IPoolV3(_pool).poolQuotaKeeper());

        address[] memory quotaTokens = pqk.quotedTokens();
        uint256 len = quotaTokens.length;
        quotas = new QuotaInfo[](len);
        unchecked {
            for (uint256 i; i < len; ++i) {
                quotas[i].token = quotaTokens[i];
                (quotas[i].rate,, quotas[i].quotaIncreaseFee, quotas[i].totalQuoted, quotas[i].limit) =
                    pqk.getTokenQuotaParams(quotaTokens[i]);
            }
        }
    }

    function getGaugesV3Data() external view returns (GaugeInfo[] memory result) {
        address[] memory poolsV3 = _listPoolsV3();
        uint256 len = poolsV3.length;
        result = new GaugeInfo[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                GaugeInfo memory gaugeInfo = result[i];
                IPoolQuotaKeeperV3 pqk = IPoolQuotaKeeperV3(IPoolV3(poolsV3[i]).poolQuotaKeeper());
                address gauge = pqk.gauge();
                gaugeInfo.addr = gauge;

                address[] memory quotaTokens = pqk.quotedTokens();
                uint256 quotaTokensLen = quotaTokens.length;
                gaugeInfo.quotaParams = new GaugeQuotaParams[](quotaTokensLen);

                for (uint256 j; j < quotaTokensLen; ++j) {
                    GaugeQuotaParams memory quotaParams = gaugeInfo.quotaParams[j];
                    address token = quotaTokens[j];
                    quotaParams.token = token;

                    (quotaParams.rate,, quotaParams.quotaIncreaseFee, quotaParams.totalQuoted, quotaParams.limit) =
                        pqk.getTokenQuotaParams(token);

                    (
                        quotaParams.minRate,
                        quotaParams.maxRate,
                        quotaParams.totalVotesLpSide,
                        quotaParams.totalVotesCaSide
                    ) = IGaugeV3(gauge).quotaRateParams(token);
                }
            }
        }
    }

    function getGaugeVotes(address staker) external view returns (GaugeVote[] memory gaugeVotes) {
        address[] memory poolsV3 = _listPoolsV3();
        uint256 len = poolsV3.length;
        uint256 index;

        unchecked {
            for (uint256 op = COUNT; op <= QUERY; ++op) {
                if (op == QUERY && index == 0) {
                    break;
                } else {
                    gaugeVotes = new GaugeVote[](index);
                    index = 0;
                }
                for (uint256 i; i < len; ++i) {
                    address[] memory quotaTokens;
                    address gauge;
                    {
                        IPoolQuotaKeeperV3 pqk = IPoolQuotaKeeperV3(IPoolV3(poolsV3[i]).poolQuotaKeeper());
                        gauge = pqk.gauge();

                        quotaTokens = pqk.quotedTokens();
                    }
                    uint256 quotaTokensLen = quotaTokens.length;

                    for (uint256 j; j < quotaTokensLen; ++j) {
                        address token = quotaTokens[j];

                        (uint96 votesLpSide, uint96 votesCaSide) = IGaugeV3(gauge).userTokenVotes(staker, token);

                        if (votesLpSide > 0 || votesCaSide > 0) {
                            if (op == QUERY) {
                                gaugeVotes[index] = GaugeVote({
                                    gauge: gauge,
                                    token: token,
                                    totalVotesLpSide: votesLpSide,
                                    totalVotesCaSide: votesCaSide
                                });
                            }
                            ++index;
                        }
                    }
                }
            }
        }
    }
}
