// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {BaseParams, BaseState} from "../types/BaseState.sol";
import {IStateSerializer} from "../interfaces/IStateSerializer.sol";
import {IStateSerializerLegacy} from "../interfaces/IStateSerializerLegacy.sol";

library BaseLib {
    function getBaseParams(address addr, bytes32 defaultContractType, address legacySerializer)
        internal
        view
        returns (BaseParams memory baseParams)
    {
        baseParams.addr = addr;
        try IVersion(addr).contractType() returns (bytes32 contractType) {
            baseParams.version = IVersion(addr).version();
            baseParams.contractType = contractType;
        } catch {
            baseParams.version = 3_00;
            baseParams.contractType = defaultContractType;
        }

        try IStateSerializer(addr).serialize() returns (bytes memory serializedParams) {
            baseParams.serializedParams = serializedParams;
        } catch {
            if (legacySerializer != address(0)) {
                baseParams.serializedParams = IStateSerializerLegacy(legacySerializer).serialize(addr);
            }
        }
    }

    function getBaseState(address addr, bytes32 defaultContractType, address legacySerializer)
        internal
        view
        returns (BaseState memory baseState)
    {
        baseState.baseParams = getBaseParams(addr, defaultContractType, legacySerializer);
    }
}
