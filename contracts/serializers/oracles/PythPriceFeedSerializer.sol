// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {PythPriceFeed} from "@gearbox-protocol/oracles-v3/contracts/oracles/updatable/PythPriceFeed.sol";
import {IStateSerializer} from "../../interfaces/IStateSerializer.sol";

contract PythPriceFeedSerializer is IStateSerializer {
    function serialize(address priceFeed) external view override returns (bytes memory) {
        PythPriceFeed pf = PythPriceFeed(payable(priceFeed));

        return abi.encode(pf.token(), pf.priceFeedId(), pf.pyth());
    }
}
