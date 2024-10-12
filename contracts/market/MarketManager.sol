// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MarketManager is Ownable {
    address public riskCurator;
    /// PriceOracleStore priceOracleStore;
    address public pool;

    // @dev Updates PriceOracles on all connected credit managers
    function updatePriceOracle() external onlyOwner {}
}
