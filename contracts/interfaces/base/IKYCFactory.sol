// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IStateSerializer} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IStateSerializer.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

/// @title  KYC factory interface
/// @author Gearbox Foundation
/// @notice Generic interface for a contract that can be used to open and manage KYC-compliant credit accounts
/// @dev    Implementations must have type `KYC_FACTORY::{POSTFIX}`
interface IKYCFactory is IVersion, IStateSerializer {
    // ------ //
    // ERRORS //
    // ------ //

    error CallerIsNotInvestorException(address caller, address creditAccount);
    error FrozenCreditAccountException(address creditAccount);
    error UnknownCreditAccountException(address creditAccount);

    // --------- //
    // FUNCTIONS //
    // --------- //

    function getTokens() external view returns (address[] memory);
    function isCreditAccount(address creditAccount) external view returns (bool);
    function getCreditAccounts(address investor) external view returns (address[] memory);
    function getInvestor(address creditAccount) external view returns (address);
    function getWallet(address creditAccount) external view returns (address);
    function isFrozen(address creditAccount) external view returns (bool);
}
