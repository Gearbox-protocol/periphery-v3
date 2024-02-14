// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {ACLNonReentrantTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLNonReentrantTrait.sol";
import {
    IAddressProviderV3,
    AP_CONTRACTS_REGISTER,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/core-v3/contracts/interfaces/IAddressProviderV3.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {
    IAddressProviderV3,
    AP_CONTRACTS_REGISTER
} from "@gearbox-protocol/core-v3/contracts/interfaces/IAddressProviderV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

contract PauseMulticall is ACLNonReentrantTrait {
    ContractsRegister public immutable cr;

    constructor(address _addressProvider) ACLNonReentrantTrait(_addressProvider) {
        cr = ContractsRegister(
            IAddressProviderV3(_addressProvider).getAddressOrRevert(AP_CONTRACTS_REGISTER, NO_VERSION_CONTROL)
        ); // F: [PM-01]
    }

    function pauseAllCreditManagers()
        external
        pausableAdminsOnly // F:[PM-05]
    {
        _pauseAllCreditManagers();
    }

    function pauseAllPools()
        external
        pausableAdminsOnly // F:[PM-05]
    {
        _pauseAllPools(); // F: [PM-03]
    }

    function pauseAllContracts()
        external
        pausableAdminsOnly // F:[PM-05]
    {
        _pauseAllPools();
        _pauseAllCreditManagers();
    }

    function _pauseAllPools() internal {
        _pauseBatchOfContracts(cr.getPools()); // F: [PM-03]
    }

    function _pauseAllCreditManagers() internal {
        address[] memory allCreditManagers = cr.getCreditManagers();

        unchecked {
            for (uint256 i = 0; i < allCreditManagers.length; ++i) {
                uint256 version = ICreditManagerV3(allCreditManagers[i]).version();
                if (version >= 3_00) {
                    allCreditManagers[i] = ICreditManagerV3(allCreditManagers[i]).creditFacade();
                }
            }
        }

        _pauseBatchOfContracts(allCreditManagers); // F: [PM-04] // F: [PM-02]
    }

    function _pauseBatchOfContracts(address[] memory contractsToPause) internal {
        uint256 len = contractsToPause.length;
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                // try-catch block to ignore some contracts which are already paused
                try ACLNonReentrantTrait(contractsToPause[i]).pause() {} catch {}
            }
        }
    }
}
