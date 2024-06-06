// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IContractsRegister} from "@gearbox-protocol/core-v3/contracts/interfaces/IContractsRegister.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {
    CollateralCalcTask,
    CollateralDebtData,
    ICreditManagerV3
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";
import {SanityCheckTrait} from "@gearbox-protocol/core-v3/contracts/traits/SanityCheckTrait.sol";

import {IAddressProviderV3} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProviderV3.sol";
import {IMarketConfiguratorV3} from "@gearbox-protocol/governance/contracts/interfaces/IMarketConfiguratorV3.sol";

import {CreditAccountData, CreditAccountFilter, CreditManagerFilter, Pagination, TokenInfo} from "./Types.sol";

/// @title  Credit account compressor
/// @notice Allows to fetch data on all credit accounts matching certain criteria in an efficient manner
/// @dev    The contract is not gas optimized and is thus not recommended for on-chain use
/// @dev    Querying functions try to process as many accounts as possible and stop when they get close to gas limit,
///         but additional pagination options are available, see `Pagination`
contract CreditAccountCompressor is IVersion, SanityCheckTrait {
    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Address provider contract address
    address public immutable ADDRESS_PROVIDER;

    /// @dev Amount of gas that covers filter matching and data preparation for a single account
    /// @dev After processing a large number of accounts, gas costs might eventually exceed this number due to
    ///      quadratic memory expansion cost and memory always growing in Solidity
    uint256 internal constant GAS_THRESHOLD = 2e6;

    /// @notice Thrown when address provider is not a contract or does not implement `marketConfigurators()`
    error InvalidAddressProviderException();

    /// @notice Constructor
    /// @param  addressProvider Address provider contract address
    constructor(address addressProvider) nonZeroAddress(addressProvider) {
        if (addressProvider.code.length == 0) revert InvalidAddressProviderException();
        try IAddressProviderV3(addressProvider).marketConfigurators() {}
        catch {
            revert InvalidAddressProviderException();
        }
        ADDRESS_PROVIDER = addressProvider;
    }

    // -------- //
    // QUERYING //
    // -------- //

    /// @notice Returns data for a particular `creditAccount`
    function getCreditAccountData(address creditAccount) external view returns (CreditAccountData memory) {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        return _getCreditAccountData(creditAccount, creditManager);
    }

    /// @notice Returns data for credit accounts that match `caFilter` in credit managers matching `cmFilter`
    /// @dev    The `false` value of `finished` return variable indicates either that return limit was reached or
    ///         that gas supplied with a call was insufficient to process all the accounts and next iteration is
    ///         needed which should start from the `nextOffset` position
    function getCreditAccounts(
        CreditManagerFilter memory cmFilter,
        CreditAccountFilter memory caFilter,
        Pagination memory pagination
    ) external view returns (CreditAccountData[] memory data, bool finished, uint256 nextOffset) {
        uint256 num = countCreditAccounts(cmFilter, caFilter, pagination);
        if (num == 0) return (data, true, 0);

        // create a second object to avoid modifying `pagination` which can have side-effects in the calling code
        Pagination memory _p = Pagination({
            offset: pagination.offset,
            scanLimit: pagination.scanLimit == 0 ? type(uint256).max : pagination.scanLimit,
            returnLimit: pagination.returnLimit == 0 ? type(uint256).max : pagination.returnLimit
        });

        data = new CreditAccountData[](Math.min(_p.returnLimit, num));
        uint256 dataOffset;

        nextOffset = _p.offset;
        address[] memory creditManagers = _getCreditManagers(cmFilter);
        for (uint256 i; i < creditManagers.length; ++i) {
            uint256 len = ICreditManagerV3(creditManagers[i]).creditAccountsLen();

            // first, we need to get to the `offset` position
            if (len <= _p.offset) {
                _p.offset -= len;
                continue;
            }

            uint256 limit = Math.min(len - _p.offset, _p.scanLimit);

            uint256 scanned;
            (dataOffset, scanned) = _getCreditAccounts({
                creditManager: creditManagers[i],
                filter: caFilter,
                data: data,
                dataOffset: dataOffset,
                offset: _p.offset,
                limit: limit
            });
            nextOffset += scanned;

            // either finished or reached one of return size or gas limits
            if (dataOffset == data.length || scanned < limit) break;

            _p.scanLimit -= limit;
            if (_p.scanLimit == 0) break;
            _p.offset = 0;
        }

        if (dataOffset < data.length) {
            // trim the array to its actual size
            assembly {
                mstore(data, dataOffset)
            }
        }

        return (data, dataOffset == num, nextOffset);
    }

    /// @notice Returns data for credit accounts that match `caFilter` in a given `creditManager`
    /// @dev    The `false` value of `finished` return variable indicates either that return limit was reached or
    ///         that gas supplied with a call was insufficient to process all the accounts and next iteration is
    ///         needed which should start from the `nextOffset` position
    function getCreditAccounts(address creditManager, CreditAccountFilter memory caFilter, Pagination memory pagination)
        external
        view
        returns (CreditAccountData[] memory data, bool finished, uint256 nextOffset)
    {
        uint256 num = countCreditAccounts(creditManager, caFilter, pagination);
        if (num == 0) return (data, true, 0);

        // create a second object to avoid modifying `pagination` which can have side-effects in the calling code
        Pagination memory _p = Pagination({
            offset: pagination.offset,
            scanLimit: pagination.scanLimit == 0 ? type(uint256).max : pagination.scanLimit,
            returnLimit: pagination.returnLimit == 0 ? type(uint256).max : pagination.returnLimit
        });

        data = new CreditAccountData[](Math.min(_p.returnLimit, num));
        uint256 dataOffset;

        uint256 len = ICreditManagerV3(creditManager).creditAccountsLen();
        // since `num != 0`, we can be sure that `len > offset`
        uint256 limit = Math.min(_p.scanLimit, len - _p.offset);

        uint256 scanned;
        (dataOffset, scanned) = _getCreditAccounts({
            creditManager: creditManager,
            filter: caFilter,
            data: data,
            dataOffset: 0,
            offset: _p.offset,
            limit: limit
        });
        nextOffset = _p.offset + scanned;

        if (dataOffset < data.length) {
            // trim the array to its actual size
            assembly {
                mstore(data, dataOffset)
            }
        }

        return (data, dataOffset == num, nextOffset);
    }

    // -------- //
    // COUNTING //
    // -------- //

    /// @notice Counts credit accounts that match `caFilter` in credit managers matching `cmFilter`
    function countCreditAccounts(
        CreditManagerFilter memory cmFilter,
        CreditAccountFilter memory caFilter,
        Pagination memory pagination
    ) public view returns (uint256 num) {
        uint256 offset = pagination.offset;
        uint256 scanLimit = pagination.scanLimit == 0 ? type(uint256).max : pagination.scanLimit;

        address[] memory creditManagers = _getCreditManagers(cmFilter);
        for (uint256 i; i < creditManagers.length; ++i) {
            uint256 len = ICreditManagerV3(creditManagers[i]).creditAccountsLen();

            // first, we need to get to the `offset` position
            if (len <= offset) {
                offset -= len;
                continue;
            }

            uint256 limit = Math.min(len - offset, scanLimit);
            num += _countCreditAccounts(creditManagers[i], caFilter, offset, limit);

            scanLimit -= limit;
            if (scanLimit == 0) break;
            offset = 0;
        }
    }

    /// @notice Counts credit accounts that match `caFilter` in a given `creditManager`
    function countCreditAccounts(
        address creditManager,
        CreditAccountFilter memory caFilter,
        Pagination memory pagination
    ) public view returns (uint256) {
        uint256 offset = pagination.offset;
        uint256 scanLimit = pagination.scanLimit == 0 ? type(uint256).max : pagination.scanLimit;

        uint256 len = ICreditManagerV3(creditManager).creditAccountsLen();
        if (len <= offset) return 0;
        uint256 limit = Math.min(len - offset, scanLimit);

        return _countCreditAccounts(creditManager, caFilter, offset, limit);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Querying implementation
    function _getCreditAccounts(
        address creditManager,
        CreditAccountFilter memory filter,
        CreditAccountData[] memory data,
        uint256 dataOffset,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256 nextDataOffset, uint256 scanned) {
        address[] memory creditAccounts = ICreditManagerV3(creditManager).creditAccounts(offset, limit);
        for (uint256 i; i < creditAccounts.length; ++i) {
            if (_checkFilterMatch(creditAccounts[i], creditManager, filter)) {
                data[dataOffset++] = _getCreditAccountData(creditAccounts[i], creditManager);
            }

            // either finished or reached one of return size or gas limits
            if (dataOffset == data.length || gasleft() < GAS_THRESHOLD) return (dataOffset, i + 1);
        }
        return (dataOffset, creditAccounts.length);
    }

    /// @dev Counting implementation
    function _countCreditAccounts(
        address creditManager,
        CreditAccountFilter memory filter,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256 num) {
        address[] memory creditAccounts = ICreditManagerV3(creditManager).creditAccounts(offset, limit);
        for (uint256 i; i < creditAccounts.length; ++i) {
            if (_checkFilterMatch(creditAccounts[i], creditManager, filter)) {
                ++num;
            }
        }
    }

    /// @dev Data loading implementation
    function _getCreditAccountData(address creditAccount, address creditManager)
        internal
        view
        returns (CreditAccountData memory data)
    {
        data.creditAccount = creditAccount;
        data.creditManager = creditManager;
        data.creditFacade = ICreditManagerV3(creditManager).creditFacade();
        data.underlying = ICreditManagerV3(creditManager).underlying();
        data.owner = ICreditManagerV3(creditManager).getBorrowerOrRevert(creditAccount);

        CollateralDebtData memory cdd =
            ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);
        data.enabledTokensMask = cdd.enabledTokensMask;
        data.debt = cdd.debt;
        data.accruedInterest = cdd.accruedInterest;
        data.accruedFees = cdd.accruedFees;

        // collateral is computed separately since it might revert on `balanceOf` and `latestRoundData` calls
        try ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL)
        returns (CollateralDebtData memory cdd_) {
            data.totalDebtUSD = cdd.totalDebtUSD;
            data.totalValueUSD = cdd_.totalValueUSD;
            data.twvUSD = cdd_.twvUSD;
            data.totalValue = cdd.totalValue;

            data.healthFactor = cdd.twvUSD * PERCENTAGE_FACTOR >= type(uint16).max * cdd.totalDebtUSD
                ? type(uint16).max
                : uint16(cdd.twvUSD * PERCENTAGE_FACTOR / cdd.totalDebtUSD);
            data.success = true;
        } catch {}

        uint256 numTokens = ICreditManagerV3(creditManager).collateralTokensCount();
        data.tokens = new TokenInfo[](numTokens);
        for (uint256 i; i < numTokens; ++i) {
            uint256 mask = 1 << i;
            address token = ICreditManagerV3(creditManager).getTokenByMask(mask);
            data.tokens[i].token = token;
            data.tokens[i].mask = mask;

            try IERC20(token).balanceOf(creditAccount) returns (uint256 balance) {
                data.tokens[i].balance = balance;
                data.tokens[i].success = true;
            } catch {}

            if (IPoolQuotaKeeperV3(cdd._poolQuotaKeeper).isQuotedToken(token)) {
                (data.tokens[i].quota,) =
                    IPoolQuotaKeeperV3(cdd._poolQuotaKeeper).getQuotaAndOutstandingInterest(creditAccount, token);
            }
        }
    }

    /// @dev Credit account filtering implementation
    function _checkFilterMatch(address creditAccount, address creditManager, CreditAccountFilter memory filter)
        internal
        view
        returns (bool)
    {
        if (filter.owner != address(0)) {
            address owner = ICreditManagerV3(creditManager).getBorrowerOrRevert(creditAccount);
            if (owner != filter.owner) return false;
        }

        if (!filter.includeZeroDebt) {
            (uint256 debt,,,,,,,) = ICreditManagerV3(creditManager).creditAccountInfo(creditAccount);
            if (debt == 0) return false;
        }

        if (filter.minHealthFactor != 0 || filter.maxHealthFactor != 0 || filter.reverting) {
            try ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL)
            returns (CollateralDebtData memory cdd) {
                if (filter.reverting) return false;
                uint16 healthFactor = cdd.twvUSD * PERCENTAGE_FACTOR >= type(uint16).max * cdd.totalDebtUSD
                    ? type(uint16).max
                    : uint16(cdd.twvUSD * PERCENTAGE_FACTOR / cdd.totalDebtUSD);
                if (filter.minHealthFactor != 0 && healthFactor < filter.minHealthFactor) return false;
                if (filter.maxHealthFactor != 0 && healthFactor > filter.maxHealthFactor) return false;
            } catch {
                if (!filter.reverting) return false;
            }
        }

        return true;
    }

    /// @dev Credit managers discovery
    function _getCreditManagers(CreditManagerFilter memory filter)
        internal
        view
        returns (address[] memory creditManagers)
    {
        address[] memory configurators = IAddressProviderV3(ADDRESS_PROVIDER).marketConfigurators();

        // rough estimate of maximum number of credit managers
        uint256 max;
        for (uint256 i; i < configurators.length; ++i) {
            address cr = IMarketConfiguratorV3(configurators[i]).contractsRegister();
            max += IContractsRegister(cr).getCreditManagers().length;
        }

        // allocate the array with maximum potentially needed size (total number of credit managers
        // can be assumed to be relatively small, so memary expansion cost is not an issue here)
        creditManagers = new address[](max);
        uint256 num;
        for (uint256 i; i < configurators.length; ++i) {
            if (filter.curator != address(0)) {
                if (IMarketConfiguratorV3(configurators[i]).owner() != filter.curator) continue;
            }

            address cr = IMarketConfiguratorV3(configurators[i]).contractsRegister();
            address[] memory managers = IContractsRegister(cr).getCreditManagers();
            for (uint256 j; j < managers.length; ++j) {
                // we're only concerned with v3 contracts
                uint256 ver = IVersion(managers[j]).version();
                if (ver < 3_00 || ver > 3_99) continue;

                if (filter.pool != address(0)) {
                    if (ICreditManagerV3(managers[j]).pool() != filter.pool) continue;
                }

                if (filter.underlying != address(0)) {
                    if (ICreditManagerV3(managers[j]).underlying() != filter.underlying) continue;
                }

                creditManagers[num++] = managers[j];
            }
        }

        // trim the array to its actual size
        assembly {
            mstore(creditManagers, num)
        }
    }
}
