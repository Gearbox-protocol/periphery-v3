// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {IStateSerializer} from "../interfaces/IStateSerializer.sol";
import {ContractAdapter} from "../types/MarketData.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {IAdapter} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IAdapter.sol";

/// @title Adapter compressor 3.0.
/// @notice Collects data from different adapter types
contract AdaptgerCompressorV3 {
    // Contract version
    uint256 public constant version = 3_10;

    function getContractAdapters(
        address creditManager
    ) external view returns (ContractAdapter[] memory adapters) {
        ICreditConfiguratorV3 creditConfigurator = ICreditConfiguratorV3(
            ICreditManagerV3(creditManager).creditConfigurator()
        );

        address[] memory allowedAdapters = creditConfigurator.allowedAdapters();
        uint256 len = allowedAdapters.length;

        adapters = new ContractAdapter[](len);
        bytes memory stateSerialised;

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address allowedAdapter = allowedAdapters[i];

                /// add try{} catch for serialisation

                // adapters[i] = ContractAdapter({
                //     targetContract: ICreditManagerV3(creditManager).adapterToContract(allowedAdapter),
                //     adapter: allowedAdapter,
                //     adapterType: uint8(IAdapter(allowedAdapter)._gearboxAdapterType()),
                //     version: IAdapter(allowedAdapter)._gearboxAdapterVersion(),
                //     stateSerialised: stateSerialised
                // });
            }
        }
    }
}
