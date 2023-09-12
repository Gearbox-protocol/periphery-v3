// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";
import {IContractsRegister} from "@gearbox-protocol/core-v2/contracts/interfaces/IContractsRegister.sol";

import {ICreditManagerV2} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditManagerV2.sol";
import {ICreditFacadeV2} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditFacadeV2.sol";
import {ICreditConfiguratorV2} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditConfiguratorV2.sol";
import {ICreditAccount} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditAccount.sol";
import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";
import {PoolService} from "@gearbox-protocol/core-v2/contracts/pool/PoolService.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

import {IAddressProvider} from "@gearbox-protocol/core-v2/contracts/interfaces/IAddressProvider.sol";
import {IDataCompressorV2_10} from "../interfaces/IDataCompressorV2_10.sol";

import {CreditAccountData, CreditManagerData, PoolData, TokenBalance, ContractAdapter} from "./Types.sol";

// EXCEPTIONS
import {ZeroAddressException} from "@gearbox-protocol/core-v2/contracts/interfaces/IErrors.sol";
import {LinearInterestModelHelper} from "./LinearInterestModelHelper.sol";

uint256 constant COUNT = 0;
uint256 constant QUERY = 1;

/// @title Data compressor 2.1.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
contract DataCompressorV2_10 is IDataCompressorV2_10, ContractsRegisterTrait, LinearInterestModelHelper {
    // Contract version
    uint256 public constant version = 2_10;

    constructor(address _addressProvider) ContractsRegisterTrait(_addressProvider) {}

    /// @dev Returns CreditAccountData for all opened accounts for particular borrower
    /// @param borrower Borrower address
    function getCreditAccountList(address borrower) external view returns (CreditAccountData[] memory result) {
        // Counts how many opened accounts a borrower has
        uint256 count;
        uint256 creditManagersLength = IContractsRegister(contractsRegister).getCreditManagersCount();
        unchecked {
            for (uint256 i = 0; i < creditManagersLength; ++i) {
                address creditManager = IContractsRegister(contractsRegister).creditManagers(i);
                if (hasOpenedCreditAccount(creditManager, borrower)) {
                    ++count;
                }
            }
        }

        result = new CreditAccountData[](count);

        // Get data & fill the array
        count = 0;
        for (uint256 i = 0; i < creditManagersLength;) {
            address creditManager = IContractsRegister(contractsRegister).creditManagers(i);
            unchecked {
                if (hasOpenedCreditAccount(creditManager, borrower)) {
                    result[count] = getCreditAccountData(creditManager, borrower);

                    count++;
                }

                ++i;
            }
        }
    }

    /// @dev Returns whether the borrower has an open credit account with the credit manager
    /// @param _creditManager Credit manager to check
    /// @param borrower Borrower to check
    function hasOpenedCreditAccount(address _creditManager, address borrower)
        public
        view
        registeredCreditManagerOnly(_creditManager)
        returns (bool)
    {
        return _hasOpenedCreditAccount(_creditManager, borrower);
    }

    /// @dev Returns CreditAccountData for a particular Credit Account account, based on creditManager and borrower
    /// @param _creditManager Credit manager address
    /// @param borrower Borrower address
    function getCreditAccountData(address _creditManager, address borrower)
        public
        view
        returns (CreditAccountData memory result)
    {
        (uint256 ver, ICreditManagerV2 creditManagerV2, ICreditFacadeV2 creditFacade,) =
            getCreditContracts(_creditManager);

        result.cfVersion = ver;

        address creditAccount = creditManagerV2.getCreditAccountOrRevert(borrower);

        result.borrower = borrower;
        result.creditManager = _creditManager;
        result.addr = creditAccount;

        result.underlying = creditManagerV2.underlying();
        (result.totalValue,) = creditFacade.calcTotalValue(creditAccount);
        result.healthFactor = creditFacade.calcCreditAccountHealthFactor(creditAccount);

        {
            (uint256 debt, uint256 borrowedAmountPlusInterest, uint256 borrowedAmountPlusInterestAndFees) =
                creditManagerV2.calcCreditAccountAccruedInterest(creditAccount);

            result.debt = debt;
            result.accruedInterest = borrowedAmountPlusInterest - debt;
            result.accruedFees = borrowedAmountPlusInterestAndFees - borrowedAmountPlusInterest;
        }

        address pool = creditManagerV2.pool();
        result.baseBorrowRate = IPoolService(pool).borrowAPY_RAY();

        uint256 collateralTokenCount = creditManagerV2.collateralTokensCount();

        result.enabledTokensMask = creditManagerV2.enabledTokensMap(creditAccount);

        result.balances = new TokenBalance[](collateralTokenCount);

        unchecked {
            for (uint256 i = 0; i < collateralTokenCount; ++i) {
                TokenBalance memory balance;
                uint256 tokenMask = 1 << i;

                (balance.token,) = creditManagerV2.collateralTokens(i);
                balance.balance = IERC20(balance.token).balanceOf(creditAccount);

                balance.isForbidden = !creditFacade.isTokenAllowed(balance.token);
                balance.isEnabled = tokenMask & result.enabledTokensMask == 0 ? false : true;

                result.balances[i] = balance;
            }
        }

        result.cumulativeIndexLastUpdate = ICreditAccount(creditAccount).cumulativeIndexAtOpen();

        result.since = uint64(ICreditAccount(creditAccount).since());
    }

    /// @dev Returns CreditManagerData for all Credit Managers
    function getCreditManagersV2List() external view returns (CreditManagerData[] memory result) {
        address[] memory cms = _listCreditManagersV2();
        uint256 creditManagersCount = cms.length;

        result = new CreditManagerData[](creditManagersCount);

        unchecked {
            for (uint256 i = 0; i < creditManagersCount; ++i) {
                result[i] = getCreditManagerData(cms[i]);
            }
        }
    }

    /// @dev Returns CreditManagerData for a particular _creditManager
    /// @param _creditManager CreditManager address
    function getCreditManagerData(address _creditManager) public view returns (CreditManagerData memory result) {
        (
            uint256 ver,
            ICreditManagerV2 creditManagerV2,
            ICreditFacadeV2 creditFacade,
            ICreditConfiguratorV2 creditConfigurator
        ) = getCreditContracts(_creditManager);

        result.addr = _creditManager;
        result.cfVersion = ver;

        result.underlying = creditManagerV2.underlying();

        {
            result.pool = creditManagerV2.pool();
            PoolService pool = PoolService(result.pool);
            result.baseBorrowRate = pool.borrowAPY_RAY();

            (uint128 currentTotalDebt, uint128 totalDebtLimit) = creditFacade.totalDebt();
            result.availableToBorrow = pool.creditManagersCanBorrow(_creditManager)
                ? Math.min(pool.availableLiquidity(), totalDebtLimit - currentTotalDebt)
                : 0;
            result.lirm = getLIRMData(address(pool.interestRateModel()));
        }

        (result.minDebt, result.maxDebt) = creditFacade.limits();

        {
            uint256 collateralTokenCount = creditManagerV2.collateralTokensCount();

            result.collateralTokens = new address[](collateralTokenCount);
            result.liquidationThresholds = new uint256[](collateralTokenCount);

            unchecked {
                for (uint256 i = 0; i < collateralTokenCount; ++i) {
                    (result.collateralTokens[i], result.liquidationThresholds[i]) = creditManagerV2.collateralTokens(i);
                }
            }
        }

        address[] memory allowedContracts = creditConfigurator.allowedContracts();
        uint256 len = allowedContracts.length;
        result.adapters = new ContractAdapter[](len);

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address targetContract = allowedContracts[i];

                result.adapters[i] = ContractAdapter({
                    targetContract: targetContract,
                    adapter: creditManagerV2.contractToAdapter(targetContract)
                });
            }
        }

        result.creditFacade = address(creditFacade);
        result.creditConfigurator = creditManagerV2.creditConfigurator();
        result.degenNFT = creditFacade.degenNFT();
        {
            bool isIncreaseDebtForbidden;
            (, isIncreaseDebtForbidden,,) = creditFacade.params(); // V2 only: true if increasing debt is forbidden

            (uint128 currentTotalDebt, uint128 totalDebtLimit) = creditFacade.totalDebt(); // V2 only: total debt and total debt limit

            result.availableToBorrow = isIncreaseDebtForbidden ? 0 : totalDebtLimit - currentTotalDebt;
        }

        result.forbiddenTokenMask = creditManagerV2.forbiddenTokenMask(); // V2 only: mask which forbids some particular tokens
        result.maxEnabledTokensLength = creditManagerV2.maxAllowedEnabledTokenLength(); // V2 only: a limit on enabled tokens imposed for security
        {
            (
                result.feeInterest,
                result.feeLiquidation,
                result.liquidationDiscount,
                result.feeLiquidationExpired,
                result.liquidationDiscountExpired
            ) = creditManagerV2.fees();
        }

        result.isPaused = Pausable(address(creditManagerV2)).paused();
    }

    /// @dev Returns PoolData for a particular pool
    /// @param _pool Pool address

    function getPoolData(address _pool) public view registeredPoolOnly(_pool) returns (PoolData memory result) {
        PoolService pool = PoolService(_pool);

        result.addr = _pool;
        result.expectedLiquidity = pool.expectedLiquidity();
        result.availableLiquidity = pool.availableLiquidity();
        result.totalBorrowed = pool.totalBorrowed();
        result.dieselRate_RAY = pool.getDieselRate_RAY();
        result.linearCumulativeIndex = pool.calcLinearCumulative_RAY();
        result.baseInterestRate = pool.borrowAPY_RAY();
        result.underlying = pool.underlyingToken();
        result.dieselToken = pool.dieselToken();
        result.dieselRate_RAY = pool.getDieselRate_RAY();
        result.withdrawFee = pool.withdrawFee();
        result.baseInterestIndexLU = pool._timestampLU();
        result.cumulativeIndex_RAY = pool._cumulativeIndex_RAY();

        uint256 dieselSupply = IERC20(result.dieselToken).totalSupply();
        uint256 totalLP = pool.fromDiesel(dieselSupply);
        result.supplyRate = totalLP == 0
            ? result.baseInterestRate
            : (result.baseInterestRate * result.totalBorrowed) * (PERCENTAGE_FACTOR - result.withdrawFee) / totalLP
                / PERCENTAGE_FACTOR;

        result.version = uint8(pool.version());
        result.lirm = getLIRMData(address(pool.interestRateModel()));

        result.isPaused = pool.paused();

        return result;
    }

    /// @dev Returns PoolData for all registered pools
    function getPoolsV1List() external view returns (PoolData[] memory result) {
        address[] memory pools = _listPoolsV1();
        uint256 poolsLength = pools.length;

        result = new PoolData[](poolsLength);
        unchecked {
            for (uint256 i = 0; i < poolsLength; ++i) {
                result[i] = getPoolData(pools[i]);
            }
        }
    }

    /// @dev Returns the adapter address for a particular creditManager and targetContract
    function getAdapter(address _creditManager, address _allowedContract)
        external
        view
        registeredCreditManagerOnly(_creditManager)
        returns (address adapter)
    {
        (, ICreditManagerV2 creditManagerV2,,) = getCreditContracts(_creditManager);

        adapter = creditManagerV2.contractToAdapter(_allowedContract);
    }

    /// @dev Internal implementation for hasOpenedCreditAccount
    function _hasOpenedCreditAccount(address creditManager, address borrower) internal view returns (bool) {
        return ICreditManagerV2(creditManager).creditAccounts(borrower) != address(0);
    }

    /// @dev Retrieves all relevant credit contracts for a particular Credit Manager
    function getCreditContracts(address _creditManager)
        internal
        view
        registeredCreditManagerOnly(_creditManager)
        returns (
            uint256 ver,
            ICreditManagerV2 creditManagerV2,
            ICreditFacadeV2 creditFacade,
            ICreditConfiguratorV2 creditConfigurator
        )
    {
        creditManagerV2 = ICreditManagerV2(_creditManager);
        creditFacade = ICreditFacadeV2(creditManagerV2.creditFacade());
        creditConfigurator = ICreditConfiguratorV2(creditManagerV2.creditConfigurator());
        ver = ICreditFacadeV2(creditFacade).version();
    }

    function _isContractV2(address _cm) internal view returns (bool) {
        uint256 cmVersion = IVersion(_cm).version();
        return cmVersion >= 2 && cmVersion < 2_99;
    }

    function _isContractV1(address _pool) internal view returns (bool) {
        uint256 cmVersion = IVersion(_pool).version();
        return cmVersion == 1;
    }

    function _listPoolsV1() internal view returns (address[] memory result) {
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

                    if (_isContractV1(_pool)) {
                        if (op == QUERY) result[index] = _pool;
                        ++index;
                    }
                }
            }
        }
    }

    function _listCreditManagersV2() internal view returns (address[] memory result) {
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

                    if (_isContractV2(_cm)) {
                        if (op == QUERY) result[index] = _cm;
                        ++index;
                    }
                }
            }
        }
    }
}
