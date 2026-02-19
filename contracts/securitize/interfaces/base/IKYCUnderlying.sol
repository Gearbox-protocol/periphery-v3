// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IStateSerializer} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IStateSerializer.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

interface IKYCUnderlying is IVersion, IStateSerializer {
    error InactiveCreditAccountException(address creditAccount);

    function factory() external view returns (address);
}
