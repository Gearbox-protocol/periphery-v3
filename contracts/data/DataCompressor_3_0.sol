// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";
import {IContractsRegister} from "@gearbox-protocol/core-v2/contracts/interfaces/IContractsRegister.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";

import {IPriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";
import {IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {IDataCompressorV3_00, PriceOnDemand} from "../interfaces/IDataCompressorV3_00.sol";

import {CreditAccountData, CreditManagerData, PoolData, TokenBalance, ContractAdapter} from "./Types.sol";

// EXCEPTIONS
import "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";

uint256 constant COUNT = 0;
uint256 constant QUERY = 1;

/// @title Data compressor 3.0.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
contract DataCompressorV3_00 is IDataCompressorV3_00, ContractsRegisterTrait {
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
        if (!_isCreditManagerV3(creditManager)) revert CreditManagerIsNotV3Exception();

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
                    address _creditManager = creditManagers[i];
                    uint256 cmVersion = IVersion(_creditManager).version();

                    if (cmVersion >= 3_00 && cmVersion < 3_99) {
                        _updatePrices(_creditManager, priceUpdates);
                        address[] memory creditAccounts = ICreditManagerV3(_creditManager).creditAccounts();
                        uint256 caLen = creditAccounts.length;
                        for (uint256 j; j < caLen; ++j) {
                            if (
                                (
                                    borrower == address(0)
                                        || ICreditManagerV3(_creditManager).getBorrowerOrRevert(creditAccounts[i])
                                            == borrower
                                )
                                    && (
                                        !liquidatableOnly
                                            || ICreditManagerV3(_creditManager).isLiquidatable(
                                                creditAccounts[i], PERCENTAGE_FACTOR
                                            )
                                    )
                            ) {
                                if (op == QUERY) {
                                    result[index] = _getCreditAccountData(_creditManager, creditAccounts[j]);
                                }
                                ++index;
                            }
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

        address _creditManager = creditAccount.creditManager();
        _ensureRegisteredCreditManager(_creditManager);
        if (!_isCreditManagerV3(_creditManager)) revert CreditManagerIsNotV3Exception();

        _updatePrices(_creditManager, priceUpdates);

        return _getCreditAccountData(_creditManager, _creditAccount);
    }

    function _getCreditAccountData(address _creditManager, address _creditAccount)
        internal
        view
        returns (CreditAccountData memory result)
    {
        ICreditManagerV3 creditManager = ICreditManagerV3(_creditManager);
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(creditManager.creditFacade());
        ICreditConfiguratorV3 creditConfigurator = ICreditConfiguratorV3(creditManager.creditConfigurator());

        result.cfVersion = creditFacade.version();

        address borrower = creditManager.getBorrowerOrRevert(_creditAccount);

        result.borrower = borrower;
        result.creditManager = _creditManager;
        result.addr = _creditAccount;

        result.underlying = creditManager.underlying();

        // (result.totalValue,) = creditFacade.calcTotalValue(creditAccount);
        // result.healthFactor = creditFacade.calcCreditAccountHealthFactor(creditAccount);

        // (result.debt, result.borrowedAmountPlusInterest, result.borrowedAmountPlusInterestAndFees) =
        //     creditManagerV2.calcCreditAccountAccruedInterest(creditAccount);

        address pool = creditManager.pool();
        result.baseBorrowRate = IPoolV3(pool).baseInterestRate();

        uint256 collateralTokenCount = creditManager.collateralTokensCount();

        result.enabledTokensMask = creditManager.enabledTokensMaskOf(_creditAccount);

        result.balances = new TokenBalance[](collateralTokenCount);

        uint256 forbiddenTokenMask = creditFacade.forbiddenTokenMask();

        unchecked {
            for (uint256 i = 0; i < collateralTokenCount; ++i) {
                TokenBalance memory balance;
                uint256 tokenMask = 1 << i;

                (balance.token,) = creditManager.collateralTokenByMask(tokenMask);
                balance.balance = IERC20(balance.token).balanceOf(_creditAccount);

                balance.isForbidden = tokenMask & forbiddenTokenMask == 0 ? false : true;
                balance.isEnabled = tokenMask & result.enabledTokensMask == 0 ? false : true;

                result.balances[i] = balance;
            }
        }

        // result.cumulativeIndexLastUpdate = ICreditAccountV3(creditAccount).cumulativeIndexAtOpen();

        // result.since = ICreditAccountV3(creditAccount).since();
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
                    address _creditManager = IContractsRegister(contractsRegister).creditManagers(i);

                    if (_isCreditManagerV3(_creditManager)) {
                        if (op == QUERY) result[index] = _creditManager;
                        ++index;
                    }
                }
            }
        }
    }

    function _isCreditManagerV3(address _creditManager) internal view returns (bool) {
        uint256 cmVersion = IVersion(_creditManager).version();
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

    /// @dev Returns CreditManagerData for a particular _creditManager
    /// @param _creditManager CreditManager address
    function getCreditManagerData(address _creditManager) public view returns (CreditManagerData memory result) {
        ICreditManagerV3 creditManager = ICreditManagerV3(_creditManager);
        ICreditConfiguratorV3 creditConfigurator = ICreditConfiguratorV3(creditManager.creditConfigurator());
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(creditManager.creditFacade());

        result.addr = _creditManager;
        result.version = creditFacade.version();

        result.underlying = creditManager.underlying();

        {
            result.pool = creditManager.pool();
            IPoolV3 pool = IPoolV3(result.pool);
            result.baseBorrowRate = pool.baseInterestRate();
            result.availableToBorrow = pool.creditManagerBorrowable(_creditManager);
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
    }

    /// @dev Returns PoolData for a particular pool
    /// @param _pool Pool address
    function getPoolData(address _pool) public view registeredPoolOnly(_pool) returns (PoolData memory result) {
        IPoolV3 pool = IPoolV3(_pool);

        result.addr = _pool;
        result.expectedLiquidity = pool.expectedLiquidity();
        // result.expectedLiquidityLimit = pool.expectedLiquidityLimit();
        result.availableLiquidity = pool.availableLiquidity();
        result.totalBorrowed = pool.totalBorrowed();
        // result.dieselRate_RAY = pool.getDieselRate_RAY();
        result.linearCumulativeIndex = pool.calcLinearCumulative_RAY();
        result.baseInterestRate = pool.baseInterestRate();
        result.underlying = pool.underlyingToken();
        result.dieselToken = address(pool);
        // result.dieselRate_RAY = pool.getDieselRate_RAY();
        result.withdrawFee = pool.withdrawFee();
        result.baseInterestIndexLU = pool.baseInterestIndexLU();
        // result.cumulativeIndex_RAY = pool.calcLinearCumulative_RAY();

        uint256 dieselSupply = pool.totalSupply();
        // uint256 totalLP = pool.convertToAssets(dieselSupply);
        result.supplyRate = pool.supplyRate();

        result.version = uint8(pool.version());

        return result;
    }

    /// @dev Returns PoolData for all registered pools
    function getPoolsV3List() external view returns (PoolData[] memory result) {
        uint256 poolsLength = IContractsRegister(contractsRegister).getPoolsCount();

        result = new PoolData[](poolsLength);
        unchecked {
            for (uint256 i = 0; i < poolsLength; ++i) {
                address pool = IContractsRegister(contractsRegister).pools(i);
                result[i] = getPoolData(pool);
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

    function _getPriceFeedFailedList(address _creditManager, TokenBalance[] memory balances)
        internal
        view
        returns (address[] memory priceFeedFailed)
    {
        uint256 len = balances.length;

        IPriceOracleV3 priceOracle = IPriceOracleV3(ICreditManagerV3(_creditManager).priceOracle());

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
}
