// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

/// @title State serializer
/// @notice Generic interface of a contract that is able to serialize state of other contracts
interface IStateSerializerLegacy {
    function serialize(address) external view returns (bytes memory);
}
