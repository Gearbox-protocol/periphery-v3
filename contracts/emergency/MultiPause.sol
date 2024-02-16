// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IContractsRegister} from "@gearbox-protocol/core-v2/contracts/interfaces/IContractsRegister.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ACLNonReentrantTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";

/// @title MultiPause
/// @author Gearbox Foundation
/// @notice Allows pausable admins to pause multiple contracts in a single transaction
/// @dev This contract is expected to be one of pausable admins in the ACL contract
contract MultiPause is ACLNonReentrantTrait, ContractsRegisterTrait {
    constructor(address addressProvider)
        ACLNonReentrantTrait(addressProvider)
        ContractsRegisterTrait(addressProvider)
    {}

    /// @notice Pauses contracts from the given list
    /// @dev Ignores contracts that are already paused
    /// @dev Reverts if caller is not a pausable admin
    function pauseContracts(address[] memory contracts) external pausableAdminsOnly {
        _pauseContracts(contracts);
    }

    /// @notice Pauses all registered pools
    /// @dev Ignores contracts that are already paused
    /// @dev Reverts if caller is not a pausable admin
    function pauseAllPools() external pausableAdminsOnly {
        _pauseAllPools();
    }

    /// @notice Pauses all registered credit managers
    /// @dev For V3, credit facades are paused instead
    /// @dev Ignores contracts that are already paused
    /// @dev Reverts if caller is not a pausable admin
    function pauseAllCreditManagers() external pausableAdminsOnly {
        _pauseAllCreditManagers();
    }

    /// @notice Pauses all registered credit managers and pools
    /// @dev Ignores contracts that are already paused
    /// @dev Reverts if caller is not a pausable admin
    function pauseAllContracts() external pausableAdminsOnly {
        _pauseAllPools();
        _pauseAllCreditManagers();
    }

    /// @dev Internal function to pause all pools
    function _pauseAllPools() internal {
        _pauseContracts(IContractsRegister(contractsRegister).getPools());
    }

    /// @dev Internal function to pause all credit managers
    function _pauseAllCreditManagers() internal {
        address[] memory contracts = IContractsRegister(contractsRegister).getCreditManagers();
        uint256 len = contracts.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                if (ICreditManagerV3(contracts[i]).version() < 3_00) continue;
                contracts[i] = ICreditManagerV3(contracts[i]).creditFacade();
            }
        }
        _pauseContracts(contracts);
    }

    /// @dev Internal function to pause contracts from the given list
    function _pauseContracts(address[] memory contracts) internal {
        uint256 len = contracts.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                if (ACLNonReentrantTrait(contracts[i]).paused()) continue;
                ACLNonReentrantTrait(contracts[i]).pause();
            }
        }
    }
}
