// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IContractsRegister} from "@gearbox-protocol/core-v2/contracts/interfaces/IContractsRegister.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ACLNonReentrantTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";

enum PausableAction {
    Pause,
    Unpause
}

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
        _pauseContracts(contracts, PausableAction.Pause);
    }

    /// @notice Pauses all registered pools
    /// @dev Ignores contracts that are already paused
    /// @dev Reverts if caller is not a pausable admin
    function pauseAllPools() external pausableAdminsOnly {
        _pauseAllPools(PausableAction.Pause);
    }

    /// @notice Pauses all registered credit managers
    /// @dev For V3, credit facades are paused instead
    /// @dev Ignores contracts that are already paused
    /// @dev Reverts if caller is not a pausable admin
    function pauseAllCreditManagers() external pausableAdminsOnly {
        _pauseAllCreditManagers(PausableAction.Pause);
    }

    /// @notice Pauses all registered credit managers and pools
    /// @dev Ignores contracts that are already paused
    /// @dev Reverts if caller is not a pausable admin
    function pauseAllContracts() external pausableAdminsOnly {
        _pauseAllPools(PausableAction.Pause);
        _pauseAllCreditManagers(PausableAction.Pause);
    }

    /// @notice Unpauses all registered credit managers and pools
    /// @dev Ignores contracts that aren't paused
    /// @dev Reverts if caller is not a unpausable admin
    function unpauseAllContracts() external unpausableAdminsOnly {
        _pauseAllPools(PausableAction.Unpause);
        _pauseAllCreditManagers(PausableAction.Unpause);
    }

    /// @dev Internal function to pause all pools
    function _pauseAllPools(PausableAction action) internal {
        _pauseContracts(IContractsRegister(contractsRegister).getPools(), action);
    }

    /// @dev Internal function to pause all credit managers
    function _pauseAllCreditManagers(PausableAction action) internal {
        address[] memory contracts = IContractsRegister(contractsRegister).getCreditManagers();
        uint256 len = contracts.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                if (ICreditManagerV3(contracts[i]).version() < 3_00) continue;
                contracts[i] = ICreditManagerV3(contracts[i]).creditFacade();
            }
        }
        _pauseContracts(contracts, action);
    }

    /// @dev Internal function to pause/unpause contracts from the given list
    function _pauseContracts(address[] memory contracts, PausableAction action) internal {
        uint256 len = contracts.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                if (action == PausableAction.Pause) {
                    if (ACLNonReentrantTrait(contracts[i]).paused()) continue;
                    ACLNonReentrantTrait(contracts[i]).pause();
                } else {
                    if (!ACLNonReentrantTrait(contracts[i]).paused()) continue;
                    ACLNonReentrantTrait(contracts[i]).unpause();
                }
            }
        }
    }
}
