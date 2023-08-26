// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2022
pragma solidity ^0.8.10;

import {CreditAccountData, CreditManagerData, PoolData, TokenInfo} from "../data/Types.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

struct PriceOnDemand {
    address token;
    bytes data;
}

interface IDataCompressorV3_00 is IVersion {
    /// @dev Returns CreditAccountData for all opened accounts for particular borrower
    /// @param borrower Borrower address
    /// @param priceUpdates Price updates for price on demand oracles
    function getCreditAccountByBorrower(address borrower, PriceOnDemand[] memory priceUpdates)
        external
        returns (CreditAccountData[] memory);

    /// @dev Returns CreditAccountData for all opened accounts for particular borrower
    /// @param creditManager Address
    /// @param priceUpdates Price updates for price on demand oracles
    function getCreditAccountByCreditManager(address creditManager, PriceOnDemand[] memory priceUpdates)
        external
        returns (CreditAccountData[] memory);

    /// @dev Returns CreditAccountData for a particular Credit Account account, based on creditManager and borrower
    /// @param creditAccount Address of credit account
    /// @param priceUpdates Price updates for price on demand oracles
    function getCreditAccountData(address creditAccount, PriceOnDemand[] memory priceUpdates)
        external
        returns (CreditAccountData memory);

    /// @dev Returns CreditManagerData for all Credit Managers
    function getCreditManagersV3List() external view returns (CreditManagerData[] memory);

    /// @dev Returns CreditManagerData for a particular _creditManager
    /// @param creditManager CreditManager address
    function getCreditManagerData(address creditManager) external view returns (CreditManagerData memory);

    /// @dev Returns PoolData for a particular pool
    /// @param _pool Pool address
    function getPoolData(address _pool) external view returns (PoolData memory);

    /// @dev Returns PoolData for all registered pools
    function getPoolsList() external view returns (PoolData[] memory);

    /// @dev Returns the adapter address for a particular creditManager and targetContract
    function getAdapter(address _creditManager, address _allowedContract) external view returns (address adapter);
}
