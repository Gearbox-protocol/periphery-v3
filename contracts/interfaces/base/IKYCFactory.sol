// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

interface IKYCFactory is IVersion {
    error CallerIsNotInvestorException(address caller, address creditAccount);
    error FrozenCreditAccountException(address creditAccount);
    error UnknownCreditAccountException(address creditAccount);

    function isCreditAccount(address creditAccount) external view returns (bool);
    function getCreditAccounts(address investor) external view returns (address[] memory);
    function getInvestor(address creditAccount) external view returns (address);
    function getWallet(address creditAccount) external view returns (address);
    function isFrozen(address creditAccount) external view returns (bool);
}
