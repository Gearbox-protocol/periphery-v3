// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {AbstractAdapter} from "@gearbox-protocol/integrations-v3/contracts/adapters/AbstractAdapter.sol";
import {IAdapter} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IAdapter.sol";
import {MigrationParams} from "./MigratorBot.sol";

contract MigratorAdapter is AbstractAdapter {
    /// @dev Legacy adapter type parameter, for compatibility with 3.0 contracts
    uint8 public constant _gearboxAdapterType = 0;

    /// @dev Legacy adapter version parameter, for compatibility with 3.0 contracts
    uint16 public constant _gearboxAdapterVersion = 3_10;

    bytes32 public constant override contractType = "ADAPTER::MIGRATOR";
    uint256 public constant override version = 3_10;

    bool public locked = true;

    modifier onlyMigratorBot() {
        if (msg.sender != targetContract) {
            revert("MigratorAdapter: caller is not the migrator bot");
        }
        _;
    }

    modifier whenUnlocked() {
        if (locked) {
            revert("MigratorAdapter: adapter is locked");
        }
        _;
    }

    constructor(address _creditManager, address _migratorBot) AbstractAdapter(_creditManager, _migratorBot) {}

    function migrate(MigrationParams memory params) external whenUnlocked creditFacadeOnly {
        _approveTokens(params.collaterals, type(uint256).max);
        _execute(msg.data);
        _approveTokens(params.collaterals, 0);
    }

    function _approveTokens(address[] memory tokens, uint256 amount) internal {
        uint256 len = tokens.length;

        for (uint256 i = 0; i < len; i++) {
            _approveToken(tokens[i], amount);
        }
    }

    function lock() external onlyMigratorBot {
        locked = true;
    }

    function unlock() external onlyMigratorBot {
        locked = false;
    }

    /// @notice Serialized adapter parameters
    function serialize() external view returns (bytes memory serializedData) {
        serializedData = abi.encode(creditManager, targetContract);
    }
}
