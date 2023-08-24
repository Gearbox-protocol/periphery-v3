// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/PercentageMath.sol";

import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";

import {ICreditManagerV2} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditManagerV2.sol";
import {ICreditFacadeV2} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditFacadeV2.sol";
import {ICreditConfiguratorV2} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditConfiguratorV2.sol";
import {ICreditAccount} from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditAccount.sol";
import {IPoolService} from "@gearbox-protocol/core-v2/contracts/interfaces/IPoolService.sol";

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

import {AddressProvider} from "@gearbox-protocol/core-v2/contracts/core/AddressProvider.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {IDataCompressorV2_10} from "../interfaces/IDataCompressorV2_10.sol";

import {CreditAccountData, CreditManagerData, PoolData, TokenInfo, TokenBalance, ContractAdapter} from "./Types.sol";

// EXCEPTIONS
import {ZeroAddressException} from "@gearbox-protocol/core-v2/contracts/interfaces/IErrors.sol";

/// @title Data compressor 2.1.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
contract DataCompressorV2_10 is IDataCompressorV2_10, ContractsRegisterTrait {
    // Contract version
    uint256 public constant version = 2_10;

    /// @dev Address of WETH
    address public immutable WETHToken;

    constructor(address _addressProvider) ContractsRegisterTrait(_addressProvider) {
        if (_addressProvider == address(0)) revert ZeroAddressException();

        addressProvider = AddressProvider(_addressProvider);
        contractsRegister = ContractsRegister(addressProvider.getContractsRegister());
        WETHToken = addressProvider.getWethToken();
    }

    /// @dev Returns CreditAccountData for all opened accounts for particular borrower
    /// @param borrower Borrower address
    function getCreditAccountList(address borrower) external view returns (CreditAccountData[] memory result) {
        // Counts how many opened accounts a borrower has
        uint256 count;
        uint256 creditManagersLength = contractsRegister.getCreditManagersCount();
        unchecked {
            for (uint256 i = 0; i < creditManagersLength; ++i) {
                address creditManager = contractsRegister.creditManagers(i);
                if (hasOpenedCreditAccount(creditManager, borrower)) {
                    ++count;
                }
            }
        }

        result = new CreditAccountData[](count);

        // Get data & fill the array
        count = 0;
        for (uint256 i = 0; i < creditManagersLength;) {
            address creditManager = contractsRegister.creditManagers(i);
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

        result.version = ver;

        address creditAccount = creditManagerV2.getCreditAccountOrRevert(borrower);

        result.borrower = borrower;
        result.creditManager = _creditManager;
        result.addr = creditAccount;

        result.underlying = creditManagerV2.underlying();
        (result.totalValue,) = creditFacade.calcTotalValue(creditAccount);
        result.healthFactor = creditFacade.calcCreditAccountHealthFactor(creditAccount);

        (result.debt, result.borrowedAmountPlusInterest, result.borrowedAmountPlusInterestAndFees) =
            creditManagerV2.calcCreditAccountAccruedInterest(creditAccount);

        address pool = creditManagerV2.pool();
        result.borrowRate = IPoolService(pool).borrowAPY_RAY();

        uint256 collateralTokenCount = creditManagerV2.collateralTokensCount();

        result.enabledTokensMask = creditManagerV2.enabledTokensMap(creditAccount);

        result.balances = new TokenBalance[](collateralTokenCount);

        unchecked {
            for (uint256 i = 0; i < collateralTokenCount; ++i) {
                TokenBalance memory balance;
                uint256 tokenMask = 1 << i;

                (balance.token,) = creditManagerV2.collateralTokens(i);
                balance.balance = IERC20(balance.token).balanceOf(creditAccount);

                balance.isAllowed = creditFacade.isTokenAllowed(balance.token);
                balance.isEnabled = tokenMask & result.enabledTokensMask == 0 ? false : true;

                result.balances[i] = balance;
            }
        }

        result.cumulativeIndexLastUpdate = ICreditAccount(creditAccount).cumulativeIndexAtOpen();

        result.since = ICreditAccount(creditAccount).since();
    }

    /// @dev Returns CreditManagerData for all Credit Managers
    function getCreditManagersList() external view returns (CreditManagerData[] memory result) {
        uint256 creditManagersCount = contractsRegister.getCreditManagersCount();

        result = new CreditManagerData[](creditManagersCount);

        unchecked {
            for (uint256 i = 0; i < creditManagersCount; ++i) {
                address creditManager = contractsRegister.creditManagers(i);
                result[i] = getCreditManagerData(creditManager);
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
        result.version = ver;

        result.underlying = creditManagerV2.underlying();
        result.isWETH = result.underlying == WETHToken;

        {
            result.pool = creditManagerV2.pool();
            IPoolService pool = IPoolService(result.pool);
            result.canBorrow = pool.creditManagersCanBorrow(_creditManager);
            result.borrowRate = pool.borrowAPY_RAY();
            result.availableLiquidity = pool.availableLiquidity();
        }

        (result.minAmount, result.maxAmount) = creditFacade.limits();

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
                address allowedContract = allowedContracts[i];

                result.adapters[i] = ContractAdapter({
                    allowedContract: allowedContract,
                    adapter: creditManagerV2.contractToAdapter(allowedContract)
                });
            }
        }

        result.creditFacade = address(creditFacade);
        result.creditConfigurator = creditManagerV2.creditConfigurator();
        result.degenNFT = creditFacade.degenNFT();
        (, result.isIncreaseDebtForbidden,,) = creditFacade.params(); // V2 only: true if increasing debt is forbidden
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
    }

    /// @dev Returns PoolData for a particular pool
    /// @param _pool Pool address
    function getPoolData(address _pool) public view registeredPoolOnly(_pool) returns (PoolData memory result) {
        IPoolService pool = IPoolService(_pool);

        result.addr = _pool;
        result.expectedLiquidity = pool.expectedLiquidity();
        result.expectedLiquidityLimit = pool.expectedLiquidityLimit();
        result.availableLiquidity = pool.availableLiquidity();
        result.totalBorrowed = pool.totalBorrowed();
        result.dieselRate_RAY = pool.getDieselRate_RAY();
        result.linearCumulativeIndex = pool.calcLinearCumulative_RAY();
        result.borrowAPY_RAY = pool.borrowAPY_RAY();
        result.underlying = pool.underlyingToken();
        result.dieselToken = pool.dieselToken();
        result.dieselRate_RAY = pool.getDieselRate_RAY();
        result.withdrawFee = pool.withdrawFee();
        result.isWETH = result.underlying == WETHToken;
        result.timestampLU = pool._timestampLU();
        result.cumulativeIndex_RAY = pool._cumulativeIndex_RAY();

        uint256 dieselSupply = IERC20(result.dieselToken).totalSupply();
        uint256 totalLP = pool.fromDiesel(dieselSupply);
        result.depositAPY_RAY = totalLP == 0
            ? result.borrowAPY_RAY
            : (result.borrowAPY_RAY * result.totalBorrowed) * (PERCENTAGE_FACTOR - result.withdrawFee) / totalLP
                / PERCENTAGE_FACTOR;

        result.version = uint8(pool.version());

        return result;
    }

    /// @dev Returns PoolData for all registered pools
    function getPoolsList() external view returns (PoolData[] memory result) {
        uint256 poolsLength = contractsRegister.getPoolsCount();

        result = new PoolData[](poolsLength);
        unchecked {
            for (uint256 i = 0; i < poolsLength; ++i) {
                address pool = contractsRegister.pools(i);
                result[i] = getPoolData(pool);
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
        targetIsRegisteredCreditManager(_creditManager)
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
}
