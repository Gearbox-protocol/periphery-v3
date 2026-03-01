// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
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
    AP_CREDIT_FACADE,
    AP_INSTANCE_MANAGER_PROXY,
    AP_MARKET_CONFIGURATOR_FACTORY,
    DOMAIN_CREDIT_MANAGER,
    DOMAIN_POOL,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/permissionless/contracts/libraries/ContractLiterals.sol";
import {Domain} from "@gearbox-protocol/permissionless/contracts/libraries/Domain.sol";

bytes32 constant DOMAIN_KYC_FACTORY = "KYC_FACTORY";
bytes32 constant DOMAIN_KYC_UNDERLYING = "KYC_UNDERLYING";
bytes32 constant DOMAIN_ON_DEMAND_LP = "ON_DEMAND_LP";

bytes32 constant TYPE_SECURITIZE_DEGEN_NFT = "DEGEN_NFT::SECURITIZE";
bytes32 constant TYPE_SECURITIZE_KYC_FACTORY = "KYC_FACTORY::SECURITIZE";
bytes32 constant TYPE_DEFAULT_KYC_UNDERLYING = "KYC_UNDERLYING::DEFAULT";
bytes32 constant TYPE_ON_DEMAND_KYC_UNDERLYING = "KYC_UNDERLYING::ON_DEMAND";
bytes32 constant TYPE_MONOPOLIZED_ON_DEMAND_LP = "ON_DEMAND_LP::MONOPOLIZED";

library AddressValidation {
    using Domain for bytes32;

    function hasType(IAddressProvider addressProvider, address deployedContract, bytes32 contractType)
        internal
        view
        returns (bool)
    {
        return isDeployedFromBytecodeRepository(addressProvider, deployedContract)
            && IVersion(deployedContract).contractType() == contractType;
    }

    function hasDomain(IAddressProvider addressProvider, address deployedContract, bytes32 domain)
        internal
        view
        returns (bool)
    {
        return isDeployedFromBytecodeRepository(addressProvider, deployedContract)
            && IVersion(deployedContract).contractType().extractDomain() == domain;
    }

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
        if (!hasDomain(addressProvider, pool, DOMAIN_POOL)) return false;
        address marketConfigurator = getMarketConfigurator(pool);
        return isMarketConfigurator(addressProvider, marketConfigurator) && isRegisteredPool(marketConfigurator, pool);
    }

    function isCreditManager(IAddressProvider addressProvider, address creditManager) internal view returns (bool) {
        if (!hasDomain(addressProvider, creditManager, DOMAIN_CREDIT_MANAGER)) return false;
        address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
        address marketConfigurator = getMarketConfigurator(creditConfigurator);
        return isMarketConfigurator(addressProvider, marketConfigurator)
            && isRegisteredCreditManager(marketConfigurator, creditManager);
    }

    function isCreditFacade(IAddressProvider addressProvider, address creditFacade) internal view returns (bool) {
        if (!hasType(addressProvider, creditFacade, AP_CREDIT_FACADE)) return false;
        address creditManager = ICreditFacadeV3(creditFacade).creditManager();
        return isCreditManager(addressProvider, creditManager)
            && ICreditManagerV3(creditManager).creditFacade() == creditFacade;
    }

    function getMarketConfigurator(address aclTrait) internal view returns (address) {
        return IACL(IACLTrait(aclTrait).acl()).getConfigurator();
    }

    function getContractsRegister(address marketConfigurator) internal view returns (address) {
        return IMarketConfigurator(marketConfigurator).contractsRegister();
    }

    function isRegisteredPool(address marketConfigurator, address pool) internal view returns (bool) {
        address contractsRegister = getContractsRegister(marketConfigurator);
        return IContractsRegister(contractsRegister).isPool(pool);
    }

    function isRegisteredCreditManager(address marketConfigurator, address creditManager) internal view returns (bool) {
        address contractsRegister = getContractsRegister(marketConfigurator);
        return IContractsRegister(contractsRegister).isCreditManager(creditManager);
    }

    function _getAddressOrRevert(IAddressProvider addressProvider, bytes32 key) private view returns (address) {
        return addressProvider.getAddressOrRevert(key, NO_VERSION_CONTROL);
    }
}
