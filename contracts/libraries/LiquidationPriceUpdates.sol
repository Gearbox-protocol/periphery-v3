// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {IPriceFeedStore, PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";

/// @title Helpers for applying and encoding on-demand price updates in liquidation compressors
library LiquidationPriceUpdates {
    function applyUpdates(address creditFacade, PriceUpdate[] memory priceUpdates) internal {
        if (priceUpdates.length == 0) return;
        address priceFeedStore = ICreditFacadeV3(creditFacade).priceFeedStore();
        IPriceFeedStore(priceFeedStore).updatePrices(priceUpdates);
    }

    /// @dev Prepends `onDemandPriceUpdates` as `calls[0]` when `priceUpdates` is non-empty.
    function prependOnDemandPriceUpdates(
        address creditFacade,
        PriceUpdate[] memory priceUpdates,
        MultiCall[] memory calls
    ) internal pure returns (MultiCall[] memory) {
        if (priceUpdates.length == 0) return calls;

        MultiCall[] memory newCalls = new MultiCall[](calls.length + 1);
        newCalls[0] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.onDemandPriceUpdates, (priceUpdates))
        });
        for (uint256 i; i < calls.length; ++i) {
            newCalls[i + 1] = calls[i];
        }
        return newCalls;
    }
}
