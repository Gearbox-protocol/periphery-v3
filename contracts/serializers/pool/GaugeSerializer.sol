// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IGaugeV3, QuotaRateParams} from "@gearbox-protocol/core-v3/contracts/interfaces/IGaugeV3.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IStateSerializerLegacy} from "../../interfaces/IStateSerializerLegacy.sol";

contract GaugeSerializer is IStateSerializerLegacy {
    function serialize(address gauge) external view override returns (bytes memory result) {
        address[] memory tokens = IPoolQuotaKeeperV3(IPoolV3(IGaugeV3(gauge).pool()).poolQuotaKeeper()).quotedTokens();
        uint256 numTokens = tokens.length;
        QuotaRateParams[] memory tokenParams = new QuotaRateParams[](numTokens);
        for (uint256 i; i < numTokens; ++i) {
            (
                tokenParams[i].minRate,
                tokenParams[i].maxRate,
                tokenParams[i].totalVotesLpSide,
                tokenParams[i].totalVotesCaSide
            ) = IGaugeV3(gauge).quotaRateParams(tokens[i]);
        }
        return abi.encode(
            IGaugeV3(gauge).voter(),
            IGaugeV3(gauge).epochLastUpdate(),
            IGaugeV3(gauge).epochFrozen(),
            tokens,
            tokenParams
        );
    }
}
