// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {BoundedPriceFeed} from "@gearbox-protocol/oracles-v3/contracts/oracles/BoundedPriceFeed.sol";
import {IStateSerializer} from "../../interfaces/IStateSerializer.sol";

contract BoundedPriceFeedSerializer is IStateSerializer {
    function serialize(address priceFeed) external view override returns (bytes memory) {
        BoundedPriceFeed pf = BoundedPriceFeed(priceFeed);

        return abi.encode(pf.upperBound());
    }
}
