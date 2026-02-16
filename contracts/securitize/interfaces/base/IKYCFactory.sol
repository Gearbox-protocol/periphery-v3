// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

interface IKYCFactory is IVersion {
    function isCreditAccount(address creditAccount) external view returns (bool);
    function isActiveCreditAccount(address creditAccount) external view returns (bool);
    function isInactiveCreditAccount(address creditAccount) external view returns (bool);
}
