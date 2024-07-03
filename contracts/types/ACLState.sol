// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

struct ACLState {
    address addr;
    uint256 version;
    address owner;
    address[] pausableAdmins;
    address[] unpausableAdmins;
    bytes serialisedData;
}
