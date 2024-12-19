// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {PendleTWAPPTPriceFeed} from "@gearbox-protocol/oracles-v3/contracts/oracles/pendle/PendleTWAPPTPriceFeed.sol";
import {IStateSerializerLegacy} from "../../interfaces/IStateSerializerLegacy.sol";

contract PendleTWAPPTPriceFeedSerializer is IStateSerializerLegacy {
    function serialize(address priceFeed) external view override returns (bytes memory) {
        PendleTWAPPTPriceFeed pf = PendleTWAPPTPriceFeed(priceFeed);

        // some already deployed price feeds like 0x9A39068aba808c15A9aAAf04fb58cC6B0E734DC1
        // don't have priceToSy() function
        bool priceToSy;
        try pf.priceToSy() returns (bool _priceToSy) {
            priceToSy = _priceToSy;
        } catch {
            priceToSy = false;
        }

        return abi.encode(pf.market(), pf.sy(), pf.yt(), pf.expiry(), pf.twapWindow(), priceToSy);
    }
}
