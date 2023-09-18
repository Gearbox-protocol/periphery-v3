// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.10;

interface IZapperRegister {
    event AddZapper(address);
    event RemoveZapper(address);

    function zappers(address pool) external view returns (address[] memory);
}
