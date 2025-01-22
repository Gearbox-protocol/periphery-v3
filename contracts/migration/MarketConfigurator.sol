// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";

import {IContractsRegisterLegacy} from
    "@gearbox-protocol/governance/contracts/market/legacy/MarketConfiguratorLegacy.sol";
import {ACL} from "@gearbox-protocol/governance/contracts/market/ACL.sol";
import {ContractsRegister} from "@gearbox-protocol/governance/contracts/market/ContractsRegister.sol";

contract LossPolicy {
    uint256 public constant version = 3_10;
}

/// @dev Extremely dumbed-down version of `MarketConfiguratorLegacy` that is just enough to let compressors work
contract MarketConfigurator {
    string public name;
    address public immutable acl;
    address public immutable treasury;
    address public immutable contractsRegister;

    constructor(string memory name_, address acl_, address contractsRegister_, address treasury_) {
        name = name_;
        acl = address(new ACL(address(this)));
        contractsRegister = address(new ContractsRegister(acl));
        treasury = treasury_;

        address[] memory pools = IContractsRegisterLegacy(contractsRegister_).getPools();
        uint256 numPools = pools.length;
        for (uint256 i; i < numPools; ++i) {
            address pool = pools[i];
            if (!_isV3Contract(pool)) continue;

            address[] memory creditManagers = IPoolV3(pool).creditManagers();
            uint256 numCreditManagers = creditManagers.length;
            if (numCreditManagers == 0) continue;

            address priceOracle = _priceOracle(creditManagers[0]);
            // NOTE: v3.0.x contracts don't have loss policies set so we don't bother with them here
            address lossPolicy = address(new LossPolicy());

            ContractsRegister(contractsRegister).registerMarket(pool, priceOracle, lossPolicy);
            for (uint256 j; j < numCreditManagers; ++j) {
                ContractsRegister(contractsRegister).registerCreditSuite(creditManagers[j]);
            }
        }
    }

    function _isV3Contract(address contract_) internal view returns (bool) {
        try IVersion(contract_).version() returns (uint256 version_) {
            return version_ >= 300 && version_ < 400;
        } catch {
            return false;
        }
    }

    function _priceOracle(address creditManager) internal view returns (address) {
        return ICreditManagerV3(creditManager).priceOracle();
    }
}
