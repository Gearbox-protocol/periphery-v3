// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IContractsRegister} from "@gearbox-protocol/core-v3/contracts/interfaces/IContractsRegister.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {
    CollateralCalcTask,
    CollateralDebtData,
    ICreditManagerV3
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {SanityCheckTrait} from "@gearbox-protocol/core-v3/contracts/traits/SanityCheckTrait.sol";

import {IAddressProviderV3} from "@gearbox-protocol/governance/contracts/interfaces/IAddressProviderV3.sol";
import {IMarketConfiguratorV3} from "@gearbox-protocol/governance/contracts/interfaces/IMarketConfiguratorV3.sol";

import {CreditAccountData, CreditAccountFilter, CreditManagerFilter, TokenInfo} from "./Types.sol";

/// @title  Credit account compressor
/// @notice Allows to fetch data on all credit accounts matching certain criteria in an efficient manner
/// @dev    The contract is not gas optimized and is thus not recommended for on-chain use
/// @dev    The querying functions exist in two modes, with one of them trying to YOLO-load everything and the other
///         one loading as many accounts as fit in the call gas limit to implement the tightest pagination possible
contract CreditAccountCompressor is IVersion, SanityCheckTrait {
    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Address provider contract address
    address public immutable addressProvider;

    /// @dev Maximum number of accounts to consider in a single step to avoid excessive memory expansion
    uint256 internal constant STEP_SIZE = 1000;

    /// @notice Thrown when address provider is not a contract or does not implement `marketConfigurators()`
    error InvalidAddressProviderException();

    /// @notice Constructor
    /// @param  addressProvider_ Address provider contract address
    constructor(address addressProvider_) nonZeroAddress(addressProvider_) {
        if (addressProvider_.code.length == 0) revert InvalidAddressProviderException();
        try IAddressProviderV3(addressProvider_).marketConfigurators() {}
        catch {
            revert InvalidAddressProviderException();
        }
        addressProvider = addressProvider_;
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
    /// @dev    The `offset` parameter specifies the position to start scanning from in the list of all
    ///         credit accounts opened in credit managers matching `cmFilter`
    /// @dev    The `false` value of `finished` return variable indicates that gas supplied with a call
    ///         was insufficient to process all the accounts and next iteration is needed which should
    ///         start from `nextOffset` position
    function getCreditAccounts(CreditManagerFilter memory cmFilter, CreditAccountFilter memory caFilter, uint256 offset)
        external
        view
        returns (CreditAccountData[] memory data, bool finished, uint256 nextOffset)
    {
        uint256 num = countCreditAccounts(cmFilter, caFilter, offset);
        nextOffset = offset;

        // FIXME: If the number of accounts matching the filter is much larger than the number of accounts that
        // can realistically be processed with most providers, pre-allocation burns unnecessarily large amount
        // of gas due to quadratic memory expansion cost.
        // An idea for the mitigation is to calculate the maximum memory pointer that can possibly be reached
        // during calculations, and write resulting data after it, only expanding memory when actually needed.
        data = new CreditAccountData[](num);
        uint256 dataOffset;

        // FIXME: This should be proven to be enough to properly return the data, and possibly made tighter
        uint256 gasThreshold = gasleft() / 64;

        address[] memory creditManagers = _getCreditManagers(cmFilter);
        for (uint256 i; i < creditManagers.length; ++i) {
            uint256 len = ICreditManagerV3(creditManagers[i]).creditAccountsLen();

            // first, we need to get to the `offset` position
            if (len <= offset) {
                offset -= len;
                continue;
            }

            while (offset < len) {
                bool outOfGas;
                uint256 processed;

                // circumvent the "Stack too deep." error
                uint256 offset_ = offset;

                (dataOffset, outOfGas, processed) = _getCreditAccounts({
                    creditManager: creditManagers[i],
                    filter: caFilter,
                    data: data,
                    dataOffset: dataOffset,
                    offset: offset_,
                    limit: STEP_SIZE,
                    gasThreshold: gasThreshold
                });
                offset += processed;
                nextOffset += processed;

                if (outOfGas) {
                    // trim the array to its actual size
                    assembly {
                        mstore(data, dataOffset)
                    }
                    return (data, dataOffset == num, nextOffset);
                }
            }
            offset = 0;
        }
        return (data, true, nextOffset);
    }

    /// @dev Same as above but with no gas limit control
    function getCreditAccounts(CreditManagerFilter memory cmFilter, CreditAccountFilter memory caFilter)
        external
        view
        returns (CreditAccountData[] memory data)
    {
        uint256 num = countCreditAccounts(cmFilter, caFilter, 0);
        data = new CreditAccountData[](num);
        uint256 dataOffset;

        address[] memory creditManagers = _getCreditManagers(cmFilter);
        for (uint256 i; i < creditManagers.length; ++i) {
            uint256 len = ICreditManagerV3(creditManagers[i]).creditAccountsLen();
            (dataOffset,,) = _getCreditAccounts({
                creditManager: creditManagers[i],
                filter: caFilter,
                data: data,
                dataOffset: dataOffset,
                offset: 0,
                limit: len,
                gasThreshold: 0
            });
        }
    }

    /// @notice Returns data for credit accounts that match `caFilter` in a given `creditManager`
    /// @dev    The `offset` parameter specifies the position to start scanning from in the list of all
    ///         credit accounts opened in `creditManager`
    /// @dev    The `false` value of `finished` return variable indicates that gas supplied with a call
    ///         was insufficient to process all the accounts and next iteration is needed which should
    ///         start from `nextOffset` position
    function getCreditAccounts(address creditManager, CreditAccountFilter memory caFilter, uint256 offset)
        external
        view
        returns (CreditAccountData[] memory data, bool finished, uint256 nextOffset)
    {
        uint256 num = countCreditAccounts(creditManager, caFilter, offset);
        nextOffset = offset;

        // FIXME: If the number of accounts matching the filter is much larger than the number of accounts that
        // can realistically be processed with most providers, pre-allocation burns unnecessarily large amount
        // of gas due to quadratic memory expansion cost.
        // An idea for the mitigation is to calculate the maximum memory pointer that can possibly be reached
        // during calculations, and write resulting data after it, only expanding memory when actually needed.
        data = new CreditAccountData[](num);
        uint256 dataOffset;

        // FIXME: This should be proven to be enough to properly return the data, and possibly made tighter
        uint256 gasThreshold = gasleft() / 64;

        uint256 len = ICreditManagerV3(creditManager).creditAccountsLen();
        while (offset < len) {
            bool outOfGas;
            uint256 processed;
            (dataOffset, outOfGas, processed) = _getCreditAccounts({
                creditManager: creditManager,
                filter: caFilter,
                data: data,
                dataOffset: dataOffset,
                offset: offset,
                limit: STEP_SIZE,
                gasThreshold: gasThreshold
            });
            offset += processed;
            nextOffset += processed;

            if (outOfGas) {
                // trim the array to its actual size
                assembly {
                    mstore(data, dataOffset)
                }
                return (data, dataOffset == num, nextOffset);
            }
        }
        return (data, true, nextOffset);
    }

    /// @dev Same as above but with no gas limit control
    function getCreditAccounts(address creditManager, CreditAccountFilter memory caFilter)
        external
        view
        returns (CreditAccountData[] memory data)
    {
        uint256 num = countCreditAccounts(creditManager, caFilter, 0);
        data = new CreditAccountData[](num);

        uint256 len = ICreditManagerV3(creditManager).creditAccountsLen();
        _getCreditAccounts({
            creditManager: creditManager,
            filter: caFilter,
            data: data,
            dataOffset: 0,
            offset: 0,
            limit: len,
            gasThreshold: 0
        });
    }

    // -------- //
    // COUNTING //
    // -------- //

    /// @notice Counts credit accounts that match `caFilter` in credit managers matching `cmFilter`
    /// @dev    The `offset` parameter specifies the position to start scanning from in the list of all
    ///         credit accounts opened in credit managers matching `cmFilter`
    function countCreditAccounts(
        CreditManagerFilter memory cmFilter,
        CreditAccountFilter memory caFilter,
        uint256 offset
    ) public view returns (uint256 num) {
        address[] memory creditManagers = _getCreditManagers(cmFilter);

        for (uint256 i; i < creditManagers.length; ++i) {
            uint256 len = ICreditManagerV3(creditManagers[i]).creditAccountsLen();

            // first, we need to get to the `offset` position
            if (len <= offset) {
                offset -= len;
                continue;
            }

            while (offset < len) {
                num += _countCreditAccounts(creditManagers[i], caFilter, offset, STEP_SIZE);
                offset += STEP_SIZE;
            }
            offset = 0;
        }
    }

    /// @notice Counts credit accounts that match `caFilter` in a given `creditManager`
    /// @dev    The `offset` parameter specifies the position to start scanning from in the list of all
    ///         credit accounts opened in `creditManager`
    function countCreditAccounts(address creditManager, CreditAccountFilter memory caFilter, uint256 offset)
        public
        view
        returns (uint256 num)
    {
        uint256 len = ICreditManagerV3(creditManager).creditAccountsLen();
        while (offset < len) {
            num += _countCreditAccounts(creditManager, caFilter, offset, STEP_SIZE);
            offset += STEP_SIZE;
        }
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
        uint256 limit,
        uint256 gasThreshold
    ) internal view returns (uint256, bool, uint256) {
        address[] memory creditAccounts = ICreditManagerV3(creditManager).creditAccounts(offset, limit);
        uint256 len = creditAccounts.length;
        for (uint256 i; i < len; ++i) {
            // early return if remaining gas is below given threshold
            if (gasleft() < gasThreshold) return (dataOffset, true, i);
            if (_checkFilterMatch(creditAccounts[i], creditManager, filter)) {
                data[dataOffset++] = _getCreditAccountData(creditAccounts[i], creditManager);
            }
        }
        return (dataOffset, false, len);
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
            data.healthFactor = cdd.totalDebtUSD == 0 ? type(uint256).max : cdd.twvUSD * 1e18 / cdd.totalDebtUSD;
            data.success = true;
        } catch {}

        uint256 numTokens = ICreditManagerV3(creditManager).collateralTokensCount();
        data.tokens = new TokenInfo[](numTokens);
        for (uint256 i; i < numTokens; ++i) {
            address token = ICreditManagerV3(creditManager).getTokenByMask(1 << i);
            data.tokens[i].token = token;

            try IERC20(token).balanceOf(creditAccount) returns (uint256 balance) {
                data.tokens[i].balance = balance;
                data.tokens[i].success = true;
            } catch {}

            // down goes quotas logic which does not apply to underlying
            if (i == 0) continue;

            (data.tokens[i].quota,) =
                IPoolQuotaKeeperV3(cdd._poolQuotaKeeper).getQuotaAndOutstandingInterest(creditAccount, token);
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
                uint256 healthFactor = cdd.totalDebtUSD == 0 ? type(uint256).max : cdd.twvUSD * 1e18 / cdd.totalDebtUSD;
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
        address[] memory configurators = IAddressProviderV3(addressProvider).marketConfigurators();

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
                uint256 ver = IVersion(managers[i]).version();
                if (ver < 3_00 || ver > 3_99) continue;

                if (filter.pool != address(0)) {
                    if (ICreditManagerV3(managers[i]).pool() != filter.pool) continue;
                }

                if (filter.underlying != address(0)) {
                    if (ICreditManagerV3(managers[i]).underlying() != filter.underlying) continue;
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
