// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IGaugeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IGaugeV3.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IStateSerializerLegacy} from "../../interfaces/IStateSerializerLegacy.sol";
import {GaugeQuotaParams} from "../../types/RateKeeperState.sol";

contract GaugeSerializer is IStateSerializerLegacy {
    function serialize(address gauge) external view override returns (bytes memory result) {
        IGaugeV3 _gauge = IGaugeV3(gauge);

        // FIXME: the function shouldn't even be called for contracts other than v3.0 gauges
        // but we need to add `serialize` to `TumblerV3` for that
        try _gauge.contractType() returns (bytes32 cType) {
            if (cType != "RATE_KEEPER::GAUGE") return "";
        } catch {
            // the only rate keepers that don't have `contractType` are v3.0 gauges
        }

        address voter = _gauge.voter();
        uint40 epochLastUpdate = _gauge.epochLastUpdate();
        bool epochFrozen = IGaugeV3(gauge).epochFrozen();

        address pool = IGaugeV3(gauge).pool();
        address pqk = IPoolV3(pool).poolQuotaKeeper();
        address[] memory quotedTokens = IPoolQuotaKeeperV3(pqk).quotedTokens();

        uint256 quotaTokensLen = quotedTokens.length;
        GaugeQuotaParams[] memory quotaParams = new GaugeQuotaParams[](quotaTokensLen);

        for (uint256 i; i < quotaTokensLen; ++i) {
            GaugeQuotaParams memory quotaParam = quotaParams[i];
            address token = quotedTokens[i];
            quotaParam.token = token;

            (quotaParam.minRate, quotaParam.maxRate, quotaParam.totalVotesLpSide, quotaParam.totalVotesCaSide) =
                IGaugeV3(gauge).quotaRateParams(token);
        }

        return abi.encode(voter, epochLastUpdate, epochFrozen, quotaParams);
    }
}
