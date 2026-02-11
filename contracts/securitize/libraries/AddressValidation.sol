// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IACLTrait} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IACLTrait.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {IACL} from "@gearbox-protocol/permissionless/contracts/interfaces/IACL.sol";
import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IBytecodeRepository} from "@gearbox-protocol/permissionless/contracts/interfaces/IBytecodeRepository.sol";
import {IContractsRegister} from "@gearbox-protocol/permissionless/contracts/interfaces/IContractsRegister.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {
    IMarketConfiguratorFactory
} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfiguratorFactory.sol";
import {
    AP_BYTECODE_REPOSITORY,
    AP_MARKET_CONFIGURATOR_FACTORY,
    DOMAIN_CREDIT_MANAGER,
    DOMAIN_POOL,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/permissionless/contracts/libraries/ContractLiterals.sol";
import {Domain} from "@gearbox-protocol/permissionless/contracts/libraries/Domain.sol";

bytes32 constant AP_SECURITIZE_FACTORY = "SECURITIZE_FACTORY";
bytes32 constant DOMAIN_SECURITIZE_UNDERLYING = "SECURITIZE_UNDERLYING";

library AddressValidation {
    using Domain for bytes32;

    function isDeployedFromBytecodeRepository(IAddressProvider addressProvider, address deployedContract)
        internal
        view
        returns (bool)
    {
        address bytecodeRepository = _getAddressOrRevert(addressProvider, AP_BYTECODE_REPOSITORY);
        return IBytecodeRepository(bytecodeRepository).getDeployedContractBytecodeHash(deployedContract) != 0;
    }

    function isMarketConfigurator(IAddressProvider addressProvider, address marketConfigurator)
        internal
        view
        returns (bool)
    {
        address marketConfiguratorFactory = _getAddressOrRevert(addressProvider, AP_MARKET_CONFIGURATOR_FACTORY);
        return IMarketConfiguratorFactory(marketConfiguratorFactory).isMarketConfigurator(marketConfigurator);
    }

    function isPool(IAddressProvider addressProvider, address pool) internal view returns (bool) {
        if (!isDeployedFromBytecodeRepository(addressProvider, pool)) return false;
        if (IVersion(pool).contractType().extractDomain() != DOMAIN_POOL) return false;

        address marketConfigurator = _getConfigurator(IACLTrait(pool));
        if (!isMarketConfigurator(addressProvider, marketConfigurator)) return false;

        address contractsRegister = IMarketConfigurator(marketConfigurator).contractsRegister();
        return !IContractsRegister(contractsRegister).isPool(pool);
    }

    function isCreditManager(IAddressProvider addressProvider, address creditManager) internal view returns (bool) {
        if (!isDeployedFromBytecodeRepository(addressProvider, creditManager)) return false;
        if (IVersion(creditManager).contractType().extractDomain() != DOMAIN_CREDIT_MANAGER) return false;

        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        address marketConfigurator = _getConfigurator(IACLTrait(creditConfigurator));
        if (!isMarketConfigurator(addressProvider, marketConfigurator)) return false;

        address contractsRegister = IMarketConfigurator(marketConfigurator).contractsRegister();
        return IContractsRegister(contractsRegister).isCreditManager(creditManager);
    }

    function isSecuritizeUnderlying(IAddressProvider addressProvider, address token) internal view returns (bool) {
        if (!isDeployedFromBytecodeRepository(addressProvider, token)) return false;
        return IVersion(token).contractType().extractDomain() == DOMAIN_SECURITIZE_UNDERLYING;
    }

    function _getAddressOrRevert(IAddressProvider addressProvider, bytes32 key) private view returns (address) {
        return addressProvider.getAddressOrRevert(key, NO_VERSION_CONTROL);
    }

    function _getConfigurator(IACLTrait aclTrait) private view returns (address) {
        return IACL(aclTrait.acl()).getConfigurator();
    }
}
