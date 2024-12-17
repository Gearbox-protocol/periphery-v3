// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {PendleTWAPPTPriceFeed} from "@gearbox-protocol/oracles-v3/contracts/oracles/pendle/PendleTWAPPTPriceFeed.sol";
import {IStateSerializerLegacy} from "../../interfaces/IStateSerializerLegacy.sol";

contract PendleTWAPPTPriceFeedSerializer is IStateSerializerLegacy {
    function serialize(address priceFeed) external view override returns (bytes memory) {
        PendleTWAPPTPriceFeed pf = PendleTWAPPTPriceFeed(priceFeed);

        return abi.encode(pf.market(), pf.sy(), pf.yt(), pf.expiry(), pf.twapWindow(), pf.priceToSy());
    }
}
